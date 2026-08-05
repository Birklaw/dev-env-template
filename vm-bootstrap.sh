#!/bin/bash
# Bootstrap a fresh Fedora VM as the base layer:
#   system packages + docker + devpod + the shared mise toolchain.
# After this, `devpod up <path-or-git-url>` spins up per-project devcontainers
# using this repo's .devcontainer as the template.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- system packages ----------
sudo dnf install -y git curl

# ---------- system libs for native Node.js / pnpm binaries ----------
# Some ARM Fedora images (especially aarch64 on cloud/edge devices) strip
# libatomic, causing "libatomic.so.1: cannot open shared object file"
# errors when running Node.js or pnpm binaries natively on the host.
if ! ldconfig -p 2>/dev/null | grep -q libatomic.so.1; then
  echo "==> Installing libatomic..."
  sudo dnf install -y libatomic
fi

# ---------- docker ----------
if ! command -v docker &>/dev/null; then
  echo "==> Installing docker..."
  sudo dnf install -y docker
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

# ---------- devpod CLI (architecture-aware) ----------
if ! command -v devpod &>/dev/null; then
  echo "==> Installing devpod CLI..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)
      DEVPOD_URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64"
      ;;
    aarch64|arm64)
      DEVPOD_URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-arm64"
      ;;
    armv7l|armhf)
      DEVPOD_URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-arm"
      ;;
    *)
      echo "ERROR: Unsupported architecture: $ARCH" >&2
      echo "Supported: x86_64, aarch64/arm64, armv7l/armhf" >&2
      exit 1
      ;;
  esac
  curl -fsSL -o /tmp/devpod "$DEVPOD_URL"
  sudo install -c -m 0755 /tmp/devpod /usr/local/bin && rm -f /tmp/devpod
fi
devpod provider add docker 2>/dev/null || devpod provider use docker || true

# ---------- dotfiles default for all devpod workspaces ----------
DOTFILES_URL="https://github.com/Birklaw/dotfiles"
DOTFILES_SCRIPT="install.sh"
devpod context set-options -o DOTFILES_URL="$DOTFILES_URL" -o DOTFILES_SCRIPT="$DOTFILES_SCRIPT"

# ---------- VS Code (one global install on the VM; NOT per container) ----------
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo dnf install -y code

# ---------- VS Code: Dev Containers extension (required for DevPod) ----------
code --install-extension ms-vscode-remote.remote-containers

# ---------- mise + shared toolset ----------
bash "$REPO_ROOT/template/setup-mise.sh"

echo "==> VM bootstrap complete."
echo "    Log out/in for docker group membership, then:"
echo "      devpod up <path-or-git-url> --ide vscode"
