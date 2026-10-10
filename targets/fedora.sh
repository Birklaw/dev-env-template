#!/bin/bash
# Fedora host bootstrap: system packages + docker + devpod, then
# the shared mise toolchain. Run via ../bootstrap.sh (or directly on a host
# being validated for the router allowlist). Distro-agnostic steps live in
# ../lib/common.sh.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_sudo_user
command -v dnf &>/dev/null || { echo "ERROR: not a dnf-based host" >&2; exit 1; }

# ---------- system packages ----------
# Containers get build-essential from the devcontainers base image.
# tmux: the dotfiles .tmux.conf assumes it (truecolor/undercurl passthrough
# for LazyVim) — not mise-managed, so it comes from the system package manager.
sudo dnf install -y git curl gh vim-enhanced gcc make tmux

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
enable_docker

# ---------- devpod CLI + dotfiles defaults ----------
install_devpod
configure_devpod

# ---------- Nerd Font symbols ----------
install_nerd_font

# ---------- mise + shared toolset ----------
run_toolchain_install

echo "==> Fedora host bootstrap complete."
echo "    Reboot (or log out/in) so docker group membership applies, then:"
echo "      devpod up <path-or-git-url> --ide none"
