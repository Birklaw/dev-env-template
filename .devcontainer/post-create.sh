#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Base toolchain (mise + global tools) — shared with the Fedora VM bootstrap.
bash "$REPO_ROOT/setup-mise.sh"

# setup-mise.sh ran in a subshell; re-add mise to PATH for what follows.
export PATH="$HOME/.local/bin:$PATH"

# If the mounted project has its own mise.toml / .tool-versions, install
# those project-specific versions too.
mise install || true

echo "==> Dev environment ready."
echo "    - node/python/go/uv/pnpm/kubectl/helm/k9s/terraform/kilo via mise (global)"
echo "    - dotfiles are applied by DevPod, not this script (see requirements.md)"
