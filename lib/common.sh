#!/bin/bash
# Shared, distro-agnostic host bootstrap steps — sourced by targets/*.sh,
# never executed directly. Targets own all package-manager verbs (dnf/apt)
# and third-party repo setup; everything here runs identically on every
# supported host. Callers run with `set -euo pipefail`.

# Repo root (this file is lib/common.sh) — reaches template/setup-mise.sh.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    -o DOTFILES_URL="https://github.com/Birklaw/dotfiles" \
    -o DOTFILES_SCRIPT="install.sh"
}

# ---------- VS Code: Dev Containers extension (required for DevPod) ------
install_vscode_extensions() {
  code --install-extension ms-vscode-remote.remote-containers
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

# ---------- mise + shared toolset ----------
run_toolchain_install() {
  # Single source of truth for the toolchain (mise-managed tools + agent
  # CLIs), shared by the host and every devcontainer.
  bash "$REPO_ROOT/template/setup-mise.sh"
}
