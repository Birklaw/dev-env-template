#!/bin/bash
# Base toolchain installer — shared by the devcontainer
# (.devcontainer/post-create.sh) and the Fedora VM bootstrap (vm-bootstrap.sh).
#
# mise is the single tool manager here: it replaces pyenv, nvm, the uv
# installer, and ad-hoc go/node/terraform/k8s installers. Tools are installed
# into mise's *global* config (~/.config/mise/config.toml) so they're always
# on PATH; per-project version overrides belong in a project-level mise.toml,
# which mise picks up automatically.
set -euo pipefail

# ---------- mise itself ----------
if ! command -v mise &>/dev/null; then
  echo "==> Installing mise..."
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# Shell activation for interactive bash sessions (idempotent).
if ! grep -q 'mise activate bash' ~/.bashrc 2>/dev/null; then
  echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
fi
eval "$(~/.local/bin/mise activate bash)"

# ---------- global toolset ----------
# Shorthands resolve via the mise registry (core/aqua backends: precompiled,
# checksum-verified). Bump these intentionally; 'mise upgrade' refreshes the
# ones pinned to latest.
mise use -g \
  node@lts \
  python@3.14 \
  go@latest \
  uv@latest \
  pnpm@latest \
  kubectl@latest \
  helm@latest \
  k9s@latest \
  terraform@latest

# Use pnpm as the installer for mise's npm: backend (persisted in
# ~/.config/mise/config.toml, applies to all future npm:* tools).
mise settings set npm.package_manager pnpm

# pnpm global bin dir for ad-hoc 'pnpm add -g <pkg>' installs (idempotent).
if ! grep -q 'PNPM_HOME' ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<'EOF'
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
EOF
fi
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# ---------- Kilo CLI (npm package, mise-managed, installed via pnpm) ----------
# Installs the 'kilo' binary; stays tracked in 'mise ls' / 'mise upgrade'.
# For one-off global npm packages outside mise: pnpm add -g <pkg>
mise use -g "npm:@kilocode/cli"

echo "==> mise toolset installed:"
mise ls
