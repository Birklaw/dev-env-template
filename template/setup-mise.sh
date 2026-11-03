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

# ---------- supply-chain policy ----------
# Hold back freshly published releases, matching the dotfiles configs:
# uv.toml `exclude-newer` and .npmrc/pnpm `min-release-age` are both 14 days.
# mise's key is minimum_release_age (default is 24h) and it applies to version
# *resolution* only: exact pins and versions recorded in mise.lock are not
# filtered, so the gate protects `mise upgrade` and floating pins (node@24).
#
# locked_scopes must be global-only (mise ignores it in project config) and is
# what makes a repo's `locked = true` work: by default locked mode enforces the
# lockfile across global, project AND system scopes, so a project lock is
# rejected for every tool that lives in the global config ("go@1.27 is not in
# the lockfile"). Limiting it to `project` keeps locked mode meaning "this
# repo's lock is complete" without inverting the global toolset, which floats
# within its pins by design.
mise settings set minimum_release_age "14d"
mise settings set locked_scopes project

# ---------- global toolset ----------
# Shorthands resolve via the mise registry (core/aqua backends: precompiled,
# checksum-verified). Pinned to the compatibility boundary rather than exact
# patches: language major.minor, semver tools' major, 0.x tools' minor, agent
# CLIs exact. Reproducible on bootstrap, while `mise upgrade` still moves within
# each pin (e.g. 0.12.x). Bump deliberately.
#
# Run from $HOME, not the caller's cwd: when invoked from a project directory
# (e.g. .devcontainer/post-create.sh), mise would otherwise resolve the
# *project's* mise.toml pins while installing the tools below. The global
# toolset must be independent of any project config — project pins are
# applied afterwards by the project's own mise.toml (post-create.sh).
cd "$HOME"

mise use -g \
  node@24 \
  python@3.14 \
  go@1.27 \
  uv@0.12 \
  pnpm@12 \
  kubectl@1.37 \
  helm@4 \
  k9s@0.51 \
  terraform@1.16 \
  flux2@2 \
  sops@3.13 \
  "github:home-operations/flate@0.6"
# flux2: GitOps CLI (mise's flux2, the Flux v2 release line).
# sops: secret encryption; 3.13 is the minor boundary (sops is pre-4.0).
# flate: not in the mise registry — the GitHub backend verifies the release
# checksum. Kept at the 0.x minor boundary like the other 0.x tools.

# ---------- terminal IDE toolset (LazyVim) ----------
# Neovim is the primary editor (LazyVim); runs on the VM and in every
# container via `devpod ssh`. mise's aqua backend ships the official
# precompiled Neovim release (LuaJIT). Version floor is set by the dotfiles
# lazy-lock.json, not by LazyVim alone: LazyVim needs >= 0.11.2, but its pinned
# nvim-treesitter commit needs >= 0.12.0 — so 0.12 is the effective minimum.
# Don't lower this without re-checking both. The Ubuntu 24.04 apt build
# (0.9.x) is far too old.
# lazygit/ripgrep/fd/fzf: LazyVim's picker + git integration (no version
# floor). tree-sitter: nvim-treesitter parser compilation needs >= 0.26.1 and
# the official binary (not npm), plus a C compiler — gcc via dnf on the VM,
# gcc/make already in the devcontainers base image.
mise use -g \
  neovim@0.12 \
  lazygit@0.66 \
  ripgrep@15 \
  fd@10 \
  fzf@0.74 \
  tree-sitter@0.27

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
  herdr@0.9 \
  "npm:@earendil-works/pi-coding-agent@1.1.0"

echo "==> mise toolset installed:"
mise ls
