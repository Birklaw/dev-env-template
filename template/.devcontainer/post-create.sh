#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- system libs (fix libatomic for Node.js / pnpm binaries) ----------
# Minimal devcontainer base images strip libatomic, causing cryptic
# "libatomic.so.1: cannot open shared object file" errors on pnpm/npm.
if ! ldconfig -p 2>/dev/null | grep -q libatomic.so.1; then
  echo "==> Installing libatomic1..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq libatomic1
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
