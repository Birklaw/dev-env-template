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
#
# Run from $HOME, not the caller's cwd: when invoked from a project directory
# (e.g. .devcontainer/post-create.sh), mise would otherwise resolve the
# *project's* mise.toml pins while installing the tools below. The global
# toolset must be independent of any project config — project pins are
# applied afterwards by the project's own mise.toml (post-create.sh).
cd "$HOME"

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

# Keep mise's npm backend on npm (the default). It ships with the node mise
# installs, so it's always version-matched. Overriding it (e.g. pnpm) couples
# every npm:* tool install to that package manager's CLI surface — pnpm 12
# removed flags mise passes (pnpm/pnpm#14281) and broke installs. pnpm itself
# stays in the toolset above for daily use.
mise settings set npm.package_manager npm

# pnpm global bin dir for ad-hoc 'pnpm add -g <pkg>' installs (idempotent).
if ! grep -q 'PNPM_HOME' ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<'EOF'
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
EOF
fi
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# ---------- Kilo CLI (npm package, mise-managed) ----------
# Installs the 'kilo' binary; stays tracked in 'mise ls' / 'mise upgrade'.
# For one-off global npm packages outside mise: pnpm add -g <pkg>
mise use -g "npm:@kilocode/cli"

echo "==> mise toolset installed:"
mise ls
