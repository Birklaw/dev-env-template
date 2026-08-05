#!/bin/bash
# Bootstrap a fresh Fedora VM as the base layer:
#   system packages + docker + devpod + the shared mise toolchain.
# After this, `devpod up <path-or-git-url>` spins up per-project devcontainers
# using this repo's .devcontainer as the template.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- system packages ----------
sudo dnf install -y git curl

# ---------- docker ----------
if ! command -v docker &>/dev/null; then
  echo "==> Installing docker..."
  sudo dnf install -y docker   # Fedora's moby-engine + docker-cli
fi
sudo systemctl enable --now docker
# Use docker without sudo (takes effect on next login, or run: newgrp docker)
sudo usermod -aG docker "$USER"

# ---------- devpod CLI ----------
if ! command -v devpod &>/dev/null; then
  echo "==> Installing devpod CLI..."
  curl -fsSL -o /tmp/devpod "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-amd64"
  sudo install -c -m 0755 /tmp/devpod /usr/local/bin && rm -f /tmp/devpod
fi
devpod provider add docker 2>/dev/null || devpod provider use docker || true

# ---------- dotfiles default for all devpod workspaces ----------
# DevPod clones this repo into every workspace and runs the install script.
DOTFILES_URL="https://github.com/Birklaw/dotfiles"   # <-- set your repo
DOTFILES_SCRIPT="install.sh"
devpod context set-options -o DOTFILES_URL="$DOTFILES_URL" -o DOTFILES_SCRIPT="$DOTFILES_SCRIPT"

# ---------- VS Code (one global install on the VM; NOT per container) ----------
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo dnf install -y code

# ---------- mise + shared toolset (same as inside containers) ----------
bash "$REPO_ROOT/template/setup-mise.sh"

echo "==> VM bootstrap complete."
echo "    Log out/in for docker group membership, then:"
echo "      devpod up <path-or-git-url> --ide vscode"
