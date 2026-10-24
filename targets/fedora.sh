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
# chromium: the browser behind the host-only chrome-devtools MCP entry (see
# verify_host_browser); it runs headless on the host and talks to a workspace's
# forwarded dev-server port. Fedora's chromium is the arm64-capable install —
# Google ships no Linux arm64 Chrome — and tracks current versions, which the
# MCP's --allowedUrlPattern needs (149+).
sudo dnf install -y git curl gh vim-enhanced gcc make tmux chromium

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

# ---------- host browser for the chrome-devtools MCP ----------
# Installed above with the base packages; this only checks the version the
# MCP's URL allowlist depends on.
verify_host_browser

# ---------- mise + shared toolset ----------
run_toolchain_install

# ---------- host dotfiles ----------
# Runs after the toolchain so install.sh's Neovim pre-warm finds a real nvim.
# The repo is cloned as a sibling of this checkout (~/projects/dev-env-template
# -> ~/projects/dotfiles) and applied with the same URL DevPod uses inside
# containers. Skip with SKIP_DOTFILES=1.
if [ "${SKIP_DOTFILES:-0}" != "1" ]; then
  sync_dotfiles_repo
  apply_host_dotfiles
fi

echo "==> Fedora host bootstrap complete."
echo "    Reboot (or log out/in) so docker group membership applies, then:"
echo "      devpod up <path-or-git-url> --ide none"
