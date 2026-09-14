#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- system packages ----------
# DEBIAN_FRONTEND=noninteractive: post-create runs without a TTY; without it
# debconf spams "unable to initialize frontend" warnings and some packages
# can hang waiting for input.
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get"

# libatomic1: minimal devcontainer base images strip libatomic, causing
# cryptic "libatomic.so.1: cannot open shared object file" errors on pnpm/npm.
if ! ldconfig -p 2>/dev/null | grep -q libatomic.so.1; then
  echo "==> Installing libatomic1..."
  $APT update -qq
  $APT install -y -qq libatomic1
fi

# vim: the base image ships vim-tiny only (as vim.tiny, not even on PATH) —
# install the full vim.
if ! command -v vim &>/dev/null; then
  echo "==> Installing vim..."
  $APT update -qq
  $APT install -y -qq vim
fi

# ---------- base toolchain (mise + global tools) ----------
bash "$REPO_ROOT/setup-mise.sh"

# setup-mise.sh ran in a subshell; re-add mise to PATH for what follows.
export PATH="$HOME/.local/bin:$PATH"

# ---------- project-level mise.toml (if present) ----------
if [[ -f "./mise.toml" || -f "../mise.toml" || -f "../../mise.toml" ]]; then
  echo "==> Found mise.toml, installing project-specific tools..."
  mise trust ./mise.toml 2>/dev/null || mise trust ../mise.toml 2>/dev/null || true
  mise install || true
fi

echo "==> Dev environment ready."
