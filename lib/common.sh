#!/bin/bash
# Shared, distro-agnostic host bootstrap steps — sourced by targets/*.sh,
# never executed directly. Targets own all package-manager verbs (dnf/apt)
# and third-party repo setup; everything here runs identically on every
# supported host. Callers run with `set -euo pipefail`.

# Repo root (this file is lib/common.sh) — reaches template/setup-mise.sh.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- dotfiles (one URL, two consumers) ----------
# DevPod applies the dotfiles INSIDE every container (DOTFILES_URL /
# DOTFILES_SCRIPT via configure_devpod). The host needs them too: herdr, pi,
# tmux and nvim all run here, and pi/mcp.json is deliberately host-only (see
# verify_host_browser). Keeping a single URL for both paths means host and
# container cannot drift apart; override it once, here or in the environment.
DOTFILES_URL="${DOTFILES_URL:-https://github.com/Birklaw/dotfiles}"
DOTFILES_SCRIPT="${DOTFILES_SCRIPT:-install.sh}"
# Space-separated, relative to $HOME. Every path listed must be a symlink
# after install.sh runs. This is the guard against install.sh's silent
# failure mode: a missing source prints "[skip]" and still exits 0, so a
# half-applied dotfiles repo otherwise looks like a successful bootstrap.
# Set to "" to disable the check.
DOTFILES_VERIFY_PATHS="${DOTFILES_VERIFY_PATHS:-.vimrc .tmux.conf .config/nvim .config/herdr/config.toml .pi/agent/AGENTS.md .pi/agent/mcp.json}"

# ---------- preflight ----------
# Bootstrap assumes a normal sudo user everywhere: scripts call `sudo ...`
# and add "$USER" to the docker group. Fresh Armbian minimal images boot as
# root with no user at all — fail fast with instructions instead of adding
# 'root' to groups further down.
require_sudo_user() {
  if [ "$(id -u)" -eq 0 ]; then
    cat >&2 <<'EOF'
ERROR: run this as a normal sudo user, not root.
On a fresh Armbian image (root by default), first create one:
  adduser <name>
  usermod -aG sudo <name>
Then log in as that user and rerun.
EOF
    exit 1
  fi
  if ! command -v sudo &>/dev/null; then
    echo "ERROR: sudo is not installed; install it as root first." >&2
    exit 1
  fi
}

# ---------- docker ----------
# Package install differs per distro (see targets/); enabling + group
# membership are identical.
enable_docker() {
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
}

# ---------- container DNS (dockerd resolvers) ----------
# dockerd fills every container's /etc/resolv.conf from the host's upstream
# resolvers. With the systemd-resolved stub it logs
#   detected 127.0.0.53 nameserver, assuming systemd-resolved,
#   so using resolv.conf: /run/systemd/resolve/resolv.conf
# and copies whatever a VPN/Tailscale put there. A tailnet stub such as
# 100.100.100.100 exists only in the host's network namespace, so containers
# cannot reach it and the first name lookup stalls (~40s) and fails -- which is
# what `git clone` exit 128 and `curl: (6)` during `devpod up` really are.
#
# Warn by default. Write the override only when DOCKER_DNS is set, because it
# changes Docker's DNS behaviour for every container on the host.
configure_docker_dns() {
  local upstream="${DOCKER_RESOLV_CONF:-/run/systemd/resolve/resolv.conf}"
  local daemon_json="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

  [ -r "$upstream" ] || return 0
  grep -qE '^nameserver[[:space:]]+(100\.100\.100\.100|100\.(6[4-9]|[7-9][0-9]|1[0-2][0-9])\.)' \
    "$upstream" || return 0

  if [ -e "$daemon_json" ]; then
    echo "==> Container DNS: $daemon_json already exists; not touching it."
    return 0
  fi

  if [ -n "${DOCKER_DNS:-}" ]; then
    local dns_json="" entry
    # Validate every entry as an IP literal before writing. A stray backslash
    # or newline would produce invalid JSON and leave dockerd down after the
    # restart below (and getent/dockerd would report it far from here).
    local ipv4='^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'
    local ipv6='^[0-9A-Fa-f]*:[0-9A-Fa-f:]*$'
    for entry in $(printf '%s' "$DOCKER_DNS" | tr ' ,' '\n\n' | sed '/^$/d'); do
      if ! printf '%s' "$entry" | grep -qE "$ipv4|$ipv6"; then
        echo "ERROR: DOCKER_DNS entry is not an IP address: $entry" >&2
        exit 1
      fi
      dns_json="${dns_json}${dns_json:+, }\"${entry}\""
    done
    if [ -z "$dns_json" ]; then
      echo "ERROR: DOCKER_DNS was set but contained no address." >&2
      exit 1
    fi
    echo "==> Container DNS: pinning dockerd resolvers to: $DOCKER_DNS"
    printf '{ "dns": [%s] }\n' "$dns_json" | sudo tee "$daemon_json" >/dev/null
    if systemctl is-active --quiet docker; then
      sudo systemctl restart docker
    fi
    echo "    [ok]   $daemon_json written"
    return 0
  fi

  cat >&2 <<'EOF'
    [warn]  containers will inherit a resolver only the host can reach
            (a VPN/Tailscale stub in /run/systemd/resolve/resolv.conf).
            Name resolution in containers will stall and fail, which surfaces
            as `git clone` exit 128 / `curl: (6)` during `devpod up`.
            Fix knowingly (host-wide, restarts containers):
              sudo tee /etc/docker/daemon.json <<'JSON'
              { "dns": ["194.242.2.2", "1.1.1.1"] }
              JSON
              sudo systemctl restart docker
            Or rerun bootstrap with DOCKER_DNS="194.242.2.2 1.1.1.1".
            Trade-off: *.ts.net MagicDNS names stop resolving in containers.
EOF
}

# ---------- docker <-> firewalld forwarding ----------
# Docker creates its `docker` zone at runtime and then logs
#   Firewalld: docker zone already exists, returning
# i.e. it never adds docker0 to it. An interface in no zone matches no policy,
# so forwarded traffic from the bridge is rejected: containers cannot reach the
# host or the internet ("Host is unreachable" / EHOSTUNREACH) while the daemon
# itself looks healthy, because it pulls images over the host netns. Observed
# on Fedora 44 with firewalld 2.4.4 + moby-engine 29.8.2.
#
# Fix: an accepting, forwarding zone containing ONLY docker0. tailscale0 is
# deliberately kept out of that zone: target="ACCEPT" would accept all traffic
# to/from the tailnet interface (unfiltered host input) and <forward/> would
# bridge the tailnet to the containers. Forwarding into the tunnel (needed while
# a Tailscale exit node is active) is granted by a narrow firewalld *policy*
# instead, which only affects forwarded traffic and leaves the tailnet's own
# zone filtering intact.
#
# Adding a zone file needs `firewall-cmd --reload`, and a reload drops Docker's
# own rules, so Docker is restarted immediately afterwards. Runs before any
# workspace exists. Idempotent: a re-run with everything in place changes
# nothing and restarts nothing.
ensure_docker_firewalld_forwarding() {
  command -v firewall-cmd &>/dev/null || return 0
  sudo docker info >/dev/null 2>&1 || return 0

  local zone=docker
  local zonefile="${DOCKER_FIREWALLD_ZONE_FILE:-/etc/firewalld/zones/docker.xml}"
  local changed=0

  if ! ip link show docker0 &>/dev/null; then
    echo "    [warn]  no docker0 interface; skipping firewalld zone setup" >&2
    return 0
  fi

  # ---- zone 'docker': docker0 only, accepting + forwarding ----
  if [ ! -f "$zonefile" ]; then
    echo "==> Adding firewalld zone '$zone' for: docker0"
    sudo install -d -m 0755 "$(dirname "$zonefile")"
    printf '%s\n' \
      '<?xml version="1.0" encoding="utf-8"?>' \
      '<zone target="ACCEPT">' \
      '  <forward/>' \
      '  <interface name="docker0"/>' \
      '</zone>' | sudo tee "$zonefile" >/dev/null
    if [ ! -f "$zonefile" ]; then
      echo "ERROR: could not write $zonefile" >&2
      exit 1
    fi
    changed=1
  fi

  # A previous revision put tailscale0 inside this ACCEPT zone. Remove it
  # (runtime and persistent) so that over-permission does not survive a re-run.
  if sudo firewall-cmd --zone="$zone" --query-interface=tailscale0 >/dev/null 2>&1; then
    sudo firewall-cmd --zone="$zone" --remove-interface=tailscale0 >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --zone="$zone" --remove-interface=tailscale0 >/dev/null 2>&1 || true
    echo "    [fix]  removed tailscale0 from zone '$zone' (it was over-permissive)"
    changed=1
  fi

  if ! sudo firewall-cmd --zone="$zone" --query-interface=docker0 >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --zone="$zone" --add-interface=docker0 >/dev/null 2>&1 ||
      echo "    [warn]  could not add docker0 to zone '$zone' permanently" >&2
    sudo firewall-cmd --zone="$zone" --add-interface=docker0 >/dev/null 2>&1 || true
    changed=1
  fi

  # ---- narrow forwarding policy: zone 'docker' -> tailscale0's zone ----
  # Only forwarded traffic between those zones is accepted; the host's own
  # input on tailscale0 stays governed by whatever zone it already belongs to.
  if ip link show tailscale0 &>/dev/null; then
    if ! firewall-cmd --help 2>&1 | grep -q -- '--new-policy'; then
      echo "    [warn]  firewalld is too old for policies; containers may not reach a Tailscale exit node" >&2
    else
      local policy=docker-tailscale-forward ts_zone egress_before="" policy_existed=0 recreate=0
      ts_zone="$(sudo firewall-cmd --get-zone-of-interface=tailscale0 2>/dev/null | awk '{print $1}')"
      if [ -z "$ts_zone" ] || [ "$ts_zone" = "$zone" ]; then
        echo "    [warn]  cannot determine a distinct firewalld zone for tailscale0; skipping forward policy" >&2
      else
        if sudo firewall-cmd --permanent --get-policies 2>/dev/null | grep -qx "$policy"; then
          policy_existed=1
          # Empty when this firewalld does not support the query; in that case
          # leave the policy alone rather than forcing a reload on every run.
          egress_before="$(sudo firewall-cmd --permanent --policy="$policy" --list-egress-zones 2>/dev/null || true)"
        fi
        if [ "$policy_existed" = 0 ] || { [ -n "$egress_before" ] && [ "$egress_before" != "$ts_zone" ]; }; then
          recreate=1
        fi
        if [ "$recreate" = 1 ]; then
          if [ "$policy_existed" = 1 ]; then
            sudo firewall-cmd --permanent --delete-policy="$policy" >/dev/null 2>&1 || true
          fi
          sudo firewall-cmd --permanent --new-policy="$policy" >/dev/null 2>&1 || true
          sudo firewall-cmd --permanent --policy="$policy" --add-ingress-zone="$zone" >/dev/null 2>&1 || true
          sudo firewall-cmd --permanent --policy="$policy" --add-egress-zone="$ts_zone" >/dev/null 2>&1 || true
          sudo firewall-cmd --permanent --policy="$policy" --set-target=ACCEPT >/dev/null 2>&1 || true
          echo "    [ok]   forward policy '$policy': zone '$zone' -> '$ts_zone'"
          changed=1
        fi
      fi
    fi
  fi

  if [ "$changed" = 1 ]; then
    sudo firewall-cmd --reload >/dev/null
    sudo systemctl restart docker
    echo "    [ok]   firewalld reloaded; docker restarted"
  else
    echo "==> docker/firewalld forwarding: already configured (docker0)"
  fi
}

# ---------- container networking smoke test ----------
# A container with no network turns every later step into a misleading error:
# `git clone` exits 128 ("Could not resolve host") inside DevPod's dotfiles
# step, which surfaces as "Error tunneling to container"; devcontainer feature
# installs die on `curl: (6) Could not resolve host` 90 seconds into a build.
# Testing it here means the bootstrap names the cause instead.
#
# The daemon (host netns) can pull images even when containers have no egress,
# so a successful pull proves nothing. `sudo docker` is deliberate: on a fresh
# host the user is not yet in the docker group (that needs a re-login).
verify_container_network() {
  local img="alpine:3" result dns egress

  echo "==> Checking container networking..."
  if ! sudo docker info >/dev/null 2>&1; then
    echo "    [warn]  docker daemon not reachable; skipping container network check" >&2
    return 0
  fi
  if ! sudo docker pull --quiet "$img" >/dev/null 2>&1; then
    echo "    [warn]  could not pull $img; skipping container network check" >&2
    return 0
  fi

  # Two independent layers, deliberately separated: name resolution (what the
  # build/apt/pnpm steps hit first) and raw egress by IP (firewall/forwarding).
  # busybox wget over plain HTTP keeps TLS and DNS out of the egress test.
  result="$(sudo docker run --rm "$img" sh -c '
    getent hosts github.com >/dev/null 2>&1 && printf "dns=ok " || printf "dns=fail "
    wget -q -T8 -O /dev/null http://1.1.1.1/ >/dev/null 2>&1 && printf "egress=ok" || printf "egress=fail"
  ' 2>/dev/null || true)"

  if [ -z "$result" ]; then
    echo "    [ERROR] could not run a container (no result from docker run)" >&2
    echo "    Reproduce manually: sudo docker run --rm $img true" >&2
    echo "    Skip this gate with SKIP_CONTAINER_NETWORK_CHECK=1 (not recommended)." >&2
    exit 1
  fi

  dns=ok
  egress=ok
  case "$result" in *dns=fail*) dns=fail ;; esac
  case "$result" in *egress=fail*) egress=fail ;; esac

  if [ "$dns" = ok ] && [ "$egress" = ok ]; then
    echo "    [ok]   containers resolve DNS and reach the internet"
    return 0
  fi

  echo "    [ERROR] container networking is broken ($result)" >&2
  if [ "$egress" = fail ]; then
    cat >&2 <<'EOF'
    Containers cannot reach the internet at all (not a DNS problem).
    Two common causes, in this order:

    1) firewalld: docker0 belongs to no zone, so the bridge hop is rejected.
         firewall-cmd --get-zone-of-interface=docker0     # expect: docker
       Rerun bootstrap (it configures the zone), or apply the fix by hand:
         sudo firewall-cmd --reload && sudo systemctl restart docker

    2) A VPN/Tailscale exit node blackholing local subnets, which includes the
       docker bridge. Check the effective route:
         ip route show table 52 | grep -E 'throw|dev tailscale0'
       If the bridge subnet appears as `dev tailscale0`, the exit node is
       blocking LAN/local traffic; enable LAN access (container traffic still
       goes through the tunnel, only local subnets bypass it):
         sudo tailscale set --exit-node-allow-lan-access=true

    Debian-family without firewalld: check ufw instead:
      sudo ufw status verbose
EOF
  else
    cat >&2 <<'EOF'
    Containers reach the internet by IP but cannot resolve names: they were
    given a resolver they cannot use. A VPN/Tailscale DNS stub on the host
    (e.g. 100.100.100.100) exists only in the host's network namespace, and
    Docker copies it into every container. Give the daemon real resolvers:
      sudo tee /etc/docker/daemon.json <<'JSON'
      { "dns": ["1.1.1.1", "8.8.8.8"] }
      JSON
      sudo systemctl restart docker
    Trade-off: *.ts.net MagicDNS names stop resolving inside containers.
    The bootstrap writes this for you when run with
    DOCKER_DNS="194.242.2.2 1.1.1.1".
EOF
  fi
  echo "    Skip this gate with SKIP_CONTAINER_NETWORK_CHECK=1 (not recommended)." >&2
  exit 1
}

# ---------- devpod CLI (architecture-aware) ----------
install_devpod() {
  if ! command -v devpod &>/dev/null; then
    echo "==> Installing devpod CLI..."
    local ARCH URL
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64)
        URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64"
        ;;
      aarch64|arm64)
        URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-arm64"
        ;;
      armv7l|armhf)
        URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-arm"
        ;;
      *)
        echo "ERROR: Unsupported architecture: $ARCH" >&2
        echo "Supported: x86_64, aarch64/arm64, armv7l/armhf" >&2
        exit 1
        ;;
    esac
    curl -fsSL -o /tmp/devpod "$URL"
    sudo install -c -m 0755 /tmp/devpod /usr/local/bin && rm -f /tmp/devpod
  fi
}

# ---------- devpod defaults for all workspaces ----------
configure_devpod() {
  devpod provider add docker 2>/dev/null || devpod provider use docker || true
  devpod context set-options \
    -o DOTFILES_URL="$DOTFILES_URL" \
    -o DOTFILES_SCRIPT="$DOTFILES_SCRIPT"
}

# ---------- Nerd Font symbols (icon glyphs for LazyVim/Neovim) ----------
# Symbols-only tarball from the official ryanoasis/nerd-fonts release, pinned
# and hash-verified: the expected SHA-256 is hardcoded here (NOT fetched from
# the release) so the trust root is this repo, not the network — a tampered or
# replaced release asset fails the check and aborts the bootstrap.
# User-local install (~/.local/share/fonts): no root, no repo attached, no
# update channel. The included fontconfig rule makes icons a *fallback*, so
# the terminal keeps its stock font and needs no profile change.
install_nerd_font() {
  local NF_VERSION="v3.5.1"
  local NF_SHA256="01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996"
  local NF_DIR="$HOME/.local/share/fonts/nerd-fonts-symbols"
  if [ -f "$NF_DIR/SymbolsNerdFontMono-Regular.ttf" ]; then
    return
  fi
  echo "==> Installing Nerd Font symbols $NF_VERSION (pinned, hash-verified)..."
  local NF_TMP
  NF_TMP="$(mktemp -d)"
  curl -fsSL -o "$NF_TMP/nf-symbols.tar.xz" \
    "https://github.com/ryanoasis/nerd-fonts/releases/download/${NF_VERSION}/NerdFontsSymbolsOnly.tar.xz"
  echo "${NF_SHA256}  $NF_TMP/nf-symbols.tar.xz" | sha256sum -c -
  mkdir -p "$NF_DIR" "$HOME/.config/fontconfig/conf.d"
  tar -xJf "$NF_TMP/nf-symbols.tar.xz" -C "$NF_DIR"
  ln -sf "$NF_DIR/10-nerd-font-symbols.conf" "$HOME/.config/fontconfig/conf.d/"
  fc-cache -f "$NF_DIR"
  rm -rf "$NF_TMP"
}

# ---------- host browser (chrome-devtools MCP) ----------
# The dotfiles ship a host-only chrome-devtools MCP entry that launches
# /usr/bin/chromium headless with --allowedUrlPattern restricted to localhost
# (see dotfiles pi/mcp.json). The allowlist is enforced by Chromium 149+; on
# older builds the flag is accepted but does not restrict anything, which would
# leave a silent false sense of containment. Warn loudly instead — non-fatal,
# because browser testing is optional and must never block a host bootstrap.
verify_host_browser() {
  local bin="/usr/bin/chromium" major
  if [ ! -x "$bin" ]; then
    echo "WARNING: $bin is missing — the chrome-devtools MCP server (dotfiles" >&2
    echo "         pi/mcp.json) will not start. Install chromium, or point" >&2
    echo "         --executablePath at an installed Chrome/Chromium." >&2
    return
  fi
  # "Chromium 154.0.8037.92 built on ..." -> 154
  major="$("$bin" --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  if [ -z "$major" ] || [ "$major" -lt 149 ]; then
    echo "WARNING: chromium ${major:-unknown} < 149 — the MCP config's" >&2
    echo "         --allowedUrlPattern allowlist is a no-op on this build, so the" >&2
    echo "         agent browser is NOT restricted to localhost. Upgrade chromium" >&2
    echo "         or remove that flag from ~/.pi/agent/mcp.json knowingly." >&2
  fi
}

# ---------- mise + shared toolset ----------
run_toolchain_install() {
  # Single source of truth for the toolchain (mise-managed tools + agent
  # CLIs), shared by the host and every devcontainer.
  bash "$REPO_ROOT/template/setup-mise.sh"
  # Skill packs for Pi — also installed in every container by
  # .devcontainer/post-create.sh. Kept here so host + container use one script.
  bash "$REPO_ROOT/template/install-skills.sh"
  # Pi packages (providers) — likewise shared with .devcontainer/post-create.sh.
  bash "$REPO_ROOT/template/install-pi-packages.sh"
}

# ---------- dotfiles on the host ----------
# Reject a local or relative DOTFILES_URL. There is no host to compare against
# in that form, so the origin check below cannot work, and a value such as
# "../../.ssh" would redirect both the clone target and the script run from it.
validate_dotfiles_url() {
  case "$DOTFILES_URL" in
    *://*|*@*:*) return 0 ;;
  esac
  echo "ERROR: DOTFILES_URL must be a git URL (https://, ssh://, git:// or user@host:path)." >&2
  echo "       Refusing to treat it as a local path: $DOTFILES_URL" >&2
  exit 1
}

# The dotfiles live as a sibling of this checkout (~/projects/dev-env-template
# -> ~/projects/dotfiles), so the bootstrap works the same whether the repos
# are cloned under ~/projects, ~/repos, or anywhere else. The name is checked
# so a URL ending in ".." / "." cannot climb out of the parent dir.
dotfiles_dir() {
  local url="${DOTFILES_URL%/}" name
  name="$(basename "$url" .git)"
  case "$name" in
    ""|.|..)
      echo "ERROR: cannot derive a safe checkout name from DOTFILES_URL: $DOTFILES_URL" >&2
      exit 1
      ;;
  esac
  printf '%s/%s\n' "$(dirname "$REPO_ROOT")" "$name"
}

# host/owner/repo, independent of scheme (ssh vs https), a user prefix, a port,
# a trailing slash or ".git". The HOST is part of the identity on purpose: a
# same-named path on another host is not our repo. Comparing only owner/repo
# would accept https://evil.example/Birklaw/dotfiles as "ours" and run it.
dotfiles_slug() {
  local ref="$1" host="" path=""
  case "$ref" in
    *://*)
      ref="${ref#*://}"
      ref="${ref#*@}"
      host="${ref%%/*}"
      host="${host%%:*}"        # drop :port
      path="${ref#*/}"
      ;;
    ?*@*:*)
      ref="${ref#*@}"
      host="${ref%%:*}"
      path="${ref#*:}"
      ;;
    *:*)
      host="${ref%%:*}"
      path="${ref#*:}"
      ;;
    *)
      path="$ref"
      ;;
  esac
  path="${path#/}"
  path="${path%.git}"
  path="${path%/}"
  printf '%s/%s\n' "${host,,}" "${path,,}"
}

# Clone the dotfiles if absent; otherwise report how the checkout relates to
# its remote. Never merges and never discards work:
#   clean + behind   -> fast-forward pull
#   dirty            -> leave the working tree alone (host uses it as-is)
#   ahead / diverged -> warn, leave it alone
# Offline is a warning, not a failure: a stale local copy still configures the
# host. Only "nothing to apply" (no clone possible) is fatal.
sync_dotfiles_repo() {
  local dir origin upstream counts ahead behind
  validate_dotfiles_url
  dir="$(dotfiles_dir)"

  if [ ! -e "$dir" ]; then
    echo "==> Cloning dotfiles: $DOTFILES_URL -> $dir"
    git clone --quiet -- "$DOTFILES_URL" "$dir"
    return 0
  fi
  if [ ! -d "$dir/.git" ]; then
    echo "ERROR: $dir exists but is not a git repository." >&2
    echo "       Move it aside, or clone $DOTFILES_URL there manually, then rerun." >&2
    exit 1
  fi

  echo "==> Dotfiles repo: $dir"
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  if [ -n "$origin" ] && [ "$(dotfiles_slug "$origin")" != "$(dotfiles_slug "$DOTFILES_URL")" ]; then
    echo "    [warn] origin is $origin, not $DOTFILES_URL" >&2
    echo "           not pulling; applying the local copy as-is" >&2
    return 0
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "    [warn] uncommitted changes present; skipping update, applying working tree" >&2
    return 0
  fi
  # Bounded: a dead network must not stall a bootstrap that is otherwise done.
  if ! timeout 60 git -C "$dir" fetch --quiet origin 2>/dev/null; then
    echo "    [warn] could not reach origin (offline?); applying local copy" >&2
    return 0
  fi
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -z "$upstream" ]; then
    echo "    [warn] no upstream branch configured; cannot compare with origin" >&2
    return 0
  fi
  # rev-list --left-right: left = commits only in HEAD (ahead),
  # right = commits only in upstream (behind).
  counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$upstream")"
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
    echo "    [ok]   up to date with $upstream"
  elif [ "$ahead" -eq 0 ]; then
    echo "    [pull] $behind commit(s) behind $upstream; fast-forwarding"
    git -C "$dir" pull --ff-only --quiet
  elif [ "$behind" -eq 0 ]; then
    echo "    [warn] $ahead local commit(s) not pushed to $upstream; applying local copy" >&2
  else
    echo "    [warn] diverged from $upstream ($ahead ahead, $behind behind); not touching it" >&2
  fi
}

# Run the dotfiles installer as the normal user (never sudo — it writes into
# $HOME) and then verify the result. install.sh exits 0 even when a source
# file is missing, so the symlink assertions are the real pass/fail gate.
apply_host_dotfiles() {
  local dir dir_real script_real path target missing=0

  validate_dotfiles_url
  dir="$(dotfiles_dir)"
  dir_real="$(realpath -m -- "$dir")"
  script_real="$(realpath -m -- "$dir/$DOTFILES_SCRIPT")"

  # DOTFILES_SCRIPT is operator-supplied, so contain it to the checkout: ".."
  # or an absolute path would otherwise execute an arbitrary file.
  case "$script_real" in
    "$dir_real"/*) ;;
    *)
      echo "ERROR: DOTFILES_SCRIPT resolves outside $dir_real: $script_real" >&2
      echo "       Refusing to execute it; use a path inside the repo." >&2
      exit 1
      ;;
  esac
  if [ ! -f "$script_real" ]; then
    echo "ERROR: $script_real not found — cannot apply dotfiles to the host." >&2
    echo "       Clone $DOTFILES_URL to $dir, or rerun with SKIP_DOTFILES=1." >&2
    exit 1
  fi

  echo
  echo "==> Applying dotfiles to $HOME (from $dir)"
  # Pin DOTFILES_DIR so install.sh cannot pick a different clone (~/.dotfiles,
  # ~/dotfiles) than the one just synced and verified here.
  ( cd "$dir_real" && DOTFILES_DIR="$dir_real" bash "$script_real" )

  if [ -n "${DOTFILES_VERIFY_PATHS// /}" ]; then
    # shellcheck disable=SC2086 # word-splitting is the point: a space-separated list
    for path in $DOTFILES_VERIFY_PATHS; do
      target="$(readlink -f -- "$HOME/$path" 2>/dev/null || true)"
      case "$target" in
        "$dir_real"/*) ;;
        *)
          echo "    [ERROR] $HOME/$path is not a symlink into $dir_real (resolved: ${target:-missing})" >&2
          missing=1
          ;;
      esac
    done
    if [ "$missing" -ne 0 ]; then
      echo "ERROR: dotfiles verification failed. Read the install output above," >&2
      echo "       fix the missing source in $dir, then rerun bootstrap." >&2
      echo "       (Disable this gate with DOTFILES_VERIFY_PATHS=\"\".)" >&2
      exit 1
    fi
    echo "    [ok]   verified symlinked paths: $DOTFILES_VERIFY_PATHS"
  fi
  if command -v herdr &>/dev/null; then
    echo "    note: if a herdr server is already running, apply the new config with"
    echo "          'herdr server reload-config' (herdr writes config at server start)."
  fi
}
