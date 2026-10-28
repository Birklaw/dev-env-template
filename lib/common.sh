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
# Pin when a tailnet stub is detected: with the container egress guard below
# (containers may only leave through the tunnel), a resolver reached over the
# LAN would break every lookup. The default is 1.1.1.1 -- neutral, reachable
# through any exit node. A Mullvad exit node's own resolver is
# DOCKER_DNS="194.242.2.2 1.1.1.1"; DOCKER_DNS overrides, and
# SKIP_DOCKER_DNS=1 restores the old warn-only behaviour.
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

  if [ "${SKIP_DOCKER_DNS:-0}" = "1" ]; then
    cat >&2 <<'EOF'
    [warn]  SKIP_DOCKER_DNS=1: containers will inherit a resolver only the host
            can reach (a VPN/Tailscale stub). Lookups will stall and fail, and
            the container egress guard will not be able to help.
            Re-run without SKIP_DOCKER_DNS, or set DOCKER_DNS to resolvers that
            work outside the host's network namespace.
EOF
    return 0
  fi

  # Neutral default (works through any exit node); DOCKER_DNS overrides.
  # `-` not `:-`: an explicitly empty DOCKER_DNS is an error, not "use default".
  local dns_list="${DOCKER_DNS-1.1.1.1}"
  local dns_json="" entry
  # Validate every entry as an IP literal before writing. A stray backslash or
  # newline would produce invalid JSON and leave dockerd down after the restart
  # below (and getent/dockerd would report it far from here).
  local ipv4='^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'
  local ipv6='^[0-9A-Fa-f]*:[0-9A-Fa-f:]*$'
  for entry in $(printf '%s' "$dns_list" | tr ' ,' '\n\n' | sed '/^$/d'); do
    if ! printf '%s' "$entry" | grep -qE "$ipv4|$ipv6"; then
      echo "ERROR: DOCKER_DNS entry is not an IP address: $entry" >&2
      exit 1
    fi
    dns_json="${dns_json}${dns_json:+, }\"${entry}\""
  done
  if [ -z "$dns_json" ]; then
    echo "ERROR: DOCKER_DNS is set but empty. Unset it to pin 1.1.1.1, or use" >&2
    echo "       SKIP_DOCKER_DNS=1 to leave container DNS alone." >&2
    exit 1
  fi
  echo "==> Container DNS: pinning dockerd resolvers to: $dns_list"
  # /etc/docker may not exist yet (nothing has written a daemon.json before),
  # and `tee` will not create it. Without this the bootstrap aborts here,
  # before docker is started and the egress guard is installed.
  sudo install -d -m 0755 "$(dirname "$daemon_json")"
  # ipv6: false is Docker's default; writing it down is the record for the
  # egress guard, which is IPv4-only.
  printf '{ "dns": [%s], "ipv6": false }\n' "$dns_json" | sudo tee "$daemon_json" >/dev/null
  if ! sudo test -f "$daemon_json"; then
    echo "ERROR: could not write $daemon_json" >&2
    exit 1
  fi
  if systemctl is-active --quiet docker; then
    sudo systemctl restart docker
  fi
  echo "    [ok]   $daemon_json written"
}

# ---------- docker <-> forward rules ----------
# Two separate problems are handled here:
#
# 1. docker0 has no firewalld zone (Docker creates its `docker` zone at runtime
#    and then logs "Firewalld: docker zone already exists, returning", so it
#    never adds its own interface). Unzoned ingress matches no policy and
#    forwarded traffic is rejected: containers cannot reach the host or the
#    internet while the daemon, pulling over the host netns, looks healthy.
#    Observed on Fedora 44 (firewalld 2.4.4, moby-engine 29.8.2).
#
# 2. Once container traffic is routed into a Tailscale exit node it has to be
#    allowed through FORWARD for both the bridge and the tunnel. Direct FORWARD
#    rules do that without touching how the tailnet's own input is filtered
#    (target=ACCEPT on tailscale0 would accept every tailnet->host port).
#
# Zone `docker` therefore stays docker0-only, and tailscale0 is *removed* from
# it if an earlier revision put it there. Bridge <-> bridge traffic is accepted
# explicitly so per-project networks (br-*) keep working.
#
# Direct rules apply at runtime immediately; the persistent copies need a
# reload, which drops Docker's chains, so a reload is followed by a Docker
# restart. Idempotent: a converged host changes nothing and restarts nothing.
# True when firewalld already has this direct rule. Prefers firewalld's own
# query (r3: comparing `--get-all-rules` strings assumes verbatim echoing;
# direct.xml does store args verbatim, but that is an implementation detail).
# Falls back to a normalized comparison that strips the
# "family table chain priority" prefix for older firewalld builds.
_direct_rule_present() {
  local scope="$1" rule="$2" all
  if firewall-cmd --help 2>&1 | grep -q -- '--query-rule'; then
    if [ "$scope" = "permanent" ]; then
      sudo firewall-cmd --permanent --direct --query-rule ipv4 filter FORWARD 0 $rule >/dev/null 2>&1
    else
      sudo firewall-cmd --direct --query-rule ipv4 filter FORWARD 0 $rule >/dev/null 2>&1
    fi
    return
  fi
  if [ "$scope" = "permanent" ]; then
    all="$(sudo firewall-cmd --permanent --direct --get-all-rules 2>/dev/null)"
  else
    all="$(sudo firewall-cmd --direct --get-all-rules 2>/dev/null)"
  fi
  printf '%s\n' "$all" |
    awk '{$1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print}' |
    grep -Fxq -- "$rule"
}

ensure_docker_firewalld_forwarding() {
  command -v firewall-cmd &>/dev/null || return 0
  sudo docker info >/dev/null 2>&1 || return 0

  local zone=docker
  local zonefile="${DOCKER_FIREWALLD_ZONE_FILE:-/etc/firewalld/zones/docker.xml}"
  local changed=0 rule

  if ! ip link show docker0 &>/dev/null; then
    echo "    [warn]  no docker0 interface; skipping firewalld setup" >&2
    return 0
  fi

  # ---- zone 'docker': docker0 only, accepting + forwarding ----
  # /etc/firewalld is 0750 root:root on Fedora, so a plain `[ -f ]` cannot even
  # stat inside zones/ as the normal user: it would report "missing" every run,
  # rewrite the file and force a reload + Docker restart on every bootstrap.
  if ! sudo test -f "$zonefile"; then
    echo "==> Adding firewalld zone '$zone' for: docker0"
    sudo install -d -m 0755 "$(dirname "$zonefile")"
    printf '%s\n' \
      '<?xml version="1.0" encoding="utf-8"?>' \
      '<zone target="ACCEPT">' \
      '  <forward/>' \
      '  <interface name="docker0"/>' \
      '</zone>' | sudo tee "$zonefile" >/dev/null
    if ! sudo test -f "$zonefile"; then
      echo "ERROR: could not write $zonefile" >&2
      exit 1
    fi
    changed=1
  fi

  if sudo firewall-cmd --zone="$zone" --query-interface=tailscale0 >/dev/null 2>&1; then
    sudo firewall-cmd --zone="$zone" --remove-interface=tailscale0 >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --zone="$zone" --remove-interface=tailscale0 >/dev/null 2>&1 || true
    echo "    [fix]  removed tailscale0 from zone '$zone' (over-permissive input)"
    changed=1
  fi

  if ! sudo firewall-cmd --zone="$zone" --query-interface=docker0 >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --zone="$zone" --add-interface=docker0 >/dev/null 2>&1 ||
      echo "    [warn]  could not add docker0 to zone '$zone' permanently" >&2
    sudo firewall-cmd --zone="$zone" --add-interface=docker0 >/dev/null 2>&1 || true
    changed=1
  fi

  # Legacy forward policy from an earlier revision: remove it, the direct rules
  # below replace it and do not depend on zone membership of tailscale0.
  if sudo firewall-cmd --permanent --get-policies 2>/dev/null | grep -qx docker-tailscale-forward; then
    sudo firewall-cmd --permanent --delete-policy=docker-tailscale-forward >/dev/null 2>&1 || true
    sudo firewall-cmd --delete-policy=docker-tailscale-forward >/dev/null 2>&1 || true
    echo "    [fix]  removed legacy policy docker-tailscale-forward"
    changed=1
  fi

  # ---- direct FORWARD rules ----
  # tailscale0 needs the tunnel hop; bridges need each other for per-project
  # compose networks. The container egress guard (below) decides whether
  # non-tunnel egress is permitted.
  local rules=(
    "-i docker0 -o tailscale0 -j ACCEPT"
    "-i br-+ -o tailscale0 -j ACCEPT"
    "-i tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    "-i docker0 -o br-+ -j ACCEPT"
    "-i br-+ -o docker0 -j ACCEPT"
    "-i br-+ -o br-+ -j ACCEPT"
  )

  for rule in "${rules[@]}"; do
    # shellcheck disable=SC2086 # rule is a whitespace-separated iptables rule
    if ! _direct_rule_present runtime "$rule"; then
      # shellcheck disable=SC2086
      sudo firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 $rule >/dev/null
      changed=1
    fi
    # shellcheck disable=SC2086
    if ! _direct_rule_present permanent "$rule"; then
      # shellcheck disable=SC2086
      sudo firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 $rule >/dev/null
      changed=1
    fi
  done

  if [ "$changed" = 1 ]; then
    echo "    [ok]   firewalld forward rules for docker0/br-*/tailscale0"
    sudo firewall-cmd --reload >/dev/null
    sudo systemctl restart docker
    echo "    [ok]   firewalld reloaded; docker restarted"
  else
    echo "==> docker/firewalld forwarding: already configured"
  fi
}

# ---------- container egress guard ----------
# Requirement: with a Tailscale exit node configured, container traffic must
# not leave by any path except the tunnel; with the exit node switched off,
# containers must work normally over the host's uplink.
#
# The logic lives in lib/container-egress-guard.sh (installed to
# /usr/local/sbin) so it is lintable, diffable and testable as its own file;
# this function only installs it plus the systemd oneshot + 5 s timer.
#
# Routing, not filtering: see the guard's header for the mechanism and its
# fail-closed behaviour. The guard is IPv4-only, matching Docker's default
# bridge; `enable_ipv6` would bypass it, so the bootstrap pins it off in
# daemon.json and warns here if a network already has it on.
#
# Skip with SKIP_CONTAINER_EGRESS_GUARD=1.
ensure_container_egress_guard() {
  [ "${SKIP_CONTAINER_EGRESS_GUARD:-0}" = "1" ] && return 0
  command -v systemctl &>/dev/null || return 0
  command -v ip &>/dev/null || return 0

  local source="$REPO_ROOT/lib/container-egress-guard.sh"
  if [ ! -f "$source" ]; then
    echo "ERROR: $source is missing" >&2
    exit 1
  fi

  local script="${CONTAINER_EGRESS_GUARD_SCRIPT:-/usr/local/sbin/container-egress-guard}"
  local unit="${CONTAINER_EGRESS_GUARD_UNIT:-/etc/systemd/system/container-egress-guard.service}"
  local timer="${CONTAINER_EGRESS_GUARD_TIMER:-/etc/systemd/system/container-egress-guard.timer}"
  local tunnel_absent="${CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT:-block}"
  local changed=0 tmp

  case "$tunnel_absent" in
    block | direct) ;;
    *)
      echo "ERROR: CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT must be block or direct" >&2
      exit 1
      ;;
  esac

  if ! sudo cmp -s "$source" "$script" 2>/dev/null; then
    sudo install -d -m 0755 "$(dirname "$script")"
    sudo install -m 0755 "$source" "$script"
    echo "==> Container egress guard installed: $script"
    changed=1
  fi

  tmp="$(mktemp)"
  cat >"$tmp" <<UNIT
[Unit]
Description=Keep Docker container egress inside the Tailscale exit node
After=network-online.target docker.service tailscaled.service firewalld.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=${tunnel_absent}
ExecStart=${script}
UNIT
  if ! sudo cmp -s "$tmp" "$unit" 2>/dev/null; then
    sudo install -d -m 0755 "$(dirname "$unit")"
    sudo install -m 0644 "$tmp" "$unit"
    changed=1
  fi
  rm -f "$tmp"

  tmp="$(mktemp)"
  cat >"$tmp" <<'TIMER'
[Unit]
Description=Reconcile the Docker container egress guard
After=container-egress-guard.service

[Timer]
OnBootSec=10s
OnUnitActiveSec=5s
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
  if ! sudo cmp -s "$tmp" "$timer" 2>/dev/null; then
    sudo install -d -m 0755 "$(dirname "$timer")"
    sudo install -m 0644 "$tmp" "$timer"
    changed=1
  fi
  rm -f "$tmp"

  if [ "$changed" = 1 ]; then
    sudo systemctl daemon-reload
    echo "==> Container egress guard: 5s reconcile, tunnel-absent=$tunnel_absent"
  fi
  sudo systemctl enable --now container-egress-guard.timer >/dev/null 2>&1 || true
  sudo systemctl start container-egress-guard.service >/dev/null 2>&1 || true

  # The guard is IPv4-only; a Docker network with IPv6 would bypass it.
  if sudo docker info >/dev/null 2>&1; then
    if sudo docker network inspect $(sudo docker network ls -q) \
      --format '{{.Name}} {{.EnableIPv6}}' 2>/dev/null | grep -q ' true$'; then
      echo "    [warn]  a Docker network has IPv6 enabled; container egress guard is IPv4-only" >&2
    fi
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
  # Pinned to the multi-arch index digest for alpine:3 (not a per-platform
  # digest) so this runs unchanged on amd64 and arm64. Refresh deliberately:
  # docker buildx imagetools inspect alpine:3
  local img="alpine:3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
  local result dns egress

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
  # nc -z opens a TCP connection straight to the IP, so neither DNS nor TLS is
  # involved (unlike wget against http://1.1.1.1/, which redirects to HTTPS).
  result="$(sudo docker run --rm "$img" sh -c '
    getent hosts github.com >/dev/null 2>&1 && printf "dns=ok " || printf "dns=fail "
    nc -z -w8 1.1.1.1 443 >/dev/null 2>&1 && printf "egress=ok" || printf "egress=fail"
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
    Diagnose in this order:

    1) Container egress guard (expected cause when an exit node is configured):
         sudo /usr/local/sbin/container-egress-guard    # reconcile now
         ip rule show | grep 'lookup 100'               # one rule per bridge subnet
         ip route show table 100                        # see below
       `default dev tailscale0` pins container traffic to the tunnel, so a
       broken tunnel breaks egress. `default blackhole` means the tunnel
       interface is missing and the guard is failing closed; set
       CONTAINER_EGRESS_GUARD_TUNNEL_ABSENT=direct before re-running bootstrap
       to fall back to the uplink instead.

    2) firewalld: docker0 belongs to no zone, so the bridge hop is rejected.
         firewall-cmd --get-zone-of-interface=docker0     # expect: docker
       Rerun bootstrap (it configures the zone), or apply the fix by hand:
         sudo firewall-cmd --reload && sudo systemctl restart docker

    3) Host <-> container / host <-> LAN only. Tailscale's exit node blackholes
       the host's local subnets; the guard does not cover host-sourced traffic,
       so the host cannot reach containers or the LAN with LAN access off:
         ip route show table 52 | grep -E 'throw|dev tailscale0'
         sudo tailscale set --exit-node-allow-lan-access=true

    Debian-family without firewalld: check ufw instead:
      sudo ufw status verbose
EOF
  else
    cat >&2 <<'EOF'
    Containers reach the internet by IP but cannot resolve names: they were
    given a resolver they cannot use (a VPN/Tailscale stub such as
    100.100.100.100 only exists inside the host's network namespace). The
    bootstrap pins /etc/docker/daemon.json by default when it detects that:
      cat /etc/docker/daemon.json
    If it is missing, re-run the bootstrap with DOCKER_DNS="1.1.1.1" (or
    "194.242.2.2 1.1.1.1" for a Mullvad exit node). SKIP_DOCKER_DNS=1 leaves
    container DNS untouched. Trade-off: *.ts.net MagicDNS names stop resolving
    inside containers.
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
