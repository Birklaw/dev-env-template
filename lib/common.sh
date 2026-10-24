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
# The dotfiles live as a sibling of this checkout (~/projects/dev-env-template
# -> ~/projects/dotfiles), so the bootstrap works the same whether the repos
# are cloned under ~/projects, ~/repos, or anywhere else.
dotfiles_dir() {
  local url="${DOTFILES_URL%/}"
  printf '%s/%s\n' "$(dirname "$REPO_ROOT")" "$(basename "$url" .git)"
}

# owner/repo, independent of ssh vs https, a user prefix, a trailing slash or
# ".git" — used only to tell "our dotfiles clone" apart from "some other repo
# at that path".
dotfiles_slug() {
  printf '%s\n' "$1" |
    sed -E 's#^[a-z+]+://##; s#^[^/]*@##; s#:([^/])#/\1#g; s#/+$##; s#\.git$##' |
    awk -F/ 'NF >= 2 { print tolower($(NF-1) "/" $NF) }'
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
  dir="$(dotfiles_dir)"

  if [ ! -e "$dir" ]; then
    echo "==> Cloning dotfiles: $DOTFILES_URL -> $dir"
    git clone --quiet "$DOTFILES_URL" "$dir"
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
  local dir script path missing=0

  dir="$(dotfiles_dir)"
  script="$dir/$DOTFILES_SCRIPT"
  if [ ! -f "$script" ]; then
    echo "ERROR: $script not found — cannot apply dotfiles to the host." >&2
    echo "       Clone $DOTFILES_URL to $dir, or rerun with SKIP_DOTFILES=1." >&2
    exit 1
  fi

  echo
  echo "==> Applying dotfiles to $HOME (from $dir)"
  ( cd "$dir" && bash "$DOTFILES_SCRIPT" )

  if [ -n "${DOTFILES_VERIFY_PATHS// /}" ]; then
    # shellcheck disable=SC2086 # word-splitting is the point: a space-separated list
    for path in $DOTFILES_VERIFY_PATHS; do
      if [ ! -L "$HOME/$path" ]; then
        echo "    [ERROR] $HOME/$path is not a symlink (dotfiles install incomplete)" >&2
        missing=1
      fi
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
