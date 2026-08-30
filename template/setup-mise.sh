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

# Resolve the actual mise binary — it may have been preinstalled via another
# channel (dnf, manual) and NOT live at ~/.local/bin/mise. Using the resolved
# path keeps the .bashrc activation and the eval below correct either way.
MISE_BIN="$(command -v mise)"

# Shell activation for interactive bash sessions (idempotent).
if ! grep -q 'mise activate bash' ~/.bashrc 2>/dev/null; then
  echo "eval \"\$($MISE_BIN activate bash)\"" >> ~/.bashrc
fi
eval "$("$MISE_BIN" activate bash)"

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

# ---------- terminal IDE toolset (LazyVim) ----------
# Neovim is the primary editor (LazyVim); runs on the VM and in every
# container via `devpod ssh`. mise's aqua backend ships the official
# precompiled Neovim release (>= 0.11.2, LuaJIT) — the Ubuntu 24.04 apt build
# (0.9.x) is too old for current LazyVim, and Fedora's lags too.
# lazygit/ripgrep/fd/fzf: LazyVim's picker + git integration. tree-sitter:
# CLI for nvim-treesitter parser compilation (also needs a C compiler —
# gcc via dnf on the VM, build-essential from the base image in containers).
mise use -g \
  neovim@latest \
  lazygit@latest \
  ripgrep@latest \
  fd@latest \
  fzf@latest \
  tree-sitter@latest

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

# ---------- agent CLIs (mise-managed) ----------
# herdr: aqua backend (checksums + GitHub artifact attestations).
# pi: npm package (@earendil-works/pi-coding-agent, binary: pi) — mise's npm
# backend needs node, which the toolset above provides. Pi's docs state
# install scripts aren't required, so mise's --ignore-scripts default is fine.
mise use -g \
  herdr@latest \
  "npm:@earendil-works/pi-coding-agent"

echo "==> mise toolset installed:"
mise ls
