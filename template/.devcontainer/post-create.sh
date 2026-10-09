#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- system packages ----------
# DEBIAN_FRONTEND=noninteractive: post-create runs without a TTY; without it
# debconf spams "unable to initialize frontend" warnings and some packages
# can hang waiting for input.
# NEEDRESTART_SUSPEND=1: newer Ubuntu images ship needrestart, which can block
# a non-interactive apt run; suspending it avoids the hang. MODE=a is kept as
# belt-and-braces for needrestart versions that ignore SUSPEND.
APT="sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 apt-get"

# Apt robustness: lock timeout for concurrent apt (host bootstrap / sibling
# containers), network timeouts + retries for flaky links (tailnet/VPN).
APT_OPTS=(-y -q
  -o DPkg::Lock::Timeout=120
  -o Acquire::http::Timeout=20
  -o Acquire::https::Timeout=20
  -o Acquire::Retries=2)

# ---------- DNS preflight ----------
# The host resolver can be a stub that
# exists only in the host netns, and a VPN/tailnet can hijack DNS so the
# container gets "Temporary failure resolving" from apt/pnpm. devcontainer.json
# pins public resolvers via runArgs --dns; check resolution before the first
# apt call so the failure is actionable instead of a wall of apt noise.
case "$(dpkg --print-architecture)" in
arm64 | armhf) APT_HOST=ports.ubuntu.com ;;
*) APT_HOST=archive.ubuntu.com ;;
esac

if ! getent hosts "$APT_HOST" >/dev/null 2>&1; then
  echo "ERROR: DNS resolution failed inside the container ($APT_HOST)." >&2
  echo "If the host uses a systemd-resolved stub or a VPN/tailnet resolver," >&2
  echo "keep the runArgs --dns entries in devcontainer.json (or point them at" >&2
  echo "a reachable resolver) and recreate the container." >&2
  exit 1
fi

$APT update

# libatomic1: minimal devcontainer base images strip libatomic, causing
# cryptic "libatomic.so.1: cannot open shared object file" errors on pnpm/npm.
if ! ldconfig -p 2>/dev/null | grep -q libatomic.so.1; then
  echo "==> Installing libatomic1..."
  $APT install "${APT_OPTS[@]}" libatomic1 </dev/null
else
  echo "==> libatomic1 install step not required."
fi

# vim: the base image ships vim-tiny only (as vim.tiny, not even on PATH) —
# install the full vim.
if ! command -v vim &>/dev/null; then
  echo "==> Installing vim..."
  $APT install "${APT_OPTS[@]}" vim </dev/null
else
  echo "==> vim install step not required."
fi

# ---------- base toolchain (mise + global tools) ----------
bash "$REPO_ROOT/setup-mise.sh"

# setup-mise.sh ran in a subshell; re-add mise to PATH for what follows.
export PATH="$HOME/.local/bin:$PATH"

# ---------- project-level mise.toml (if present) ----------
# Fail closed: a broken project pin should surface here, not silently leave the
# container on the global toolchain.
MISE_TOML=""
for candidate in ./mise.toml ../mise.toml ../../mise.toml; do
  if [[ -f "$candidate" ]]; then
    MISE_TOML="$candidate"
    break
  fi
done
if [[ -n "$MISE_TOML" ]]; then
  echo "==> Found $MISE_TOML, installing project-specific tools..."
  mise trust "$MISE_TOML"
  mise install
fi

echo "==> Dev environment ready."
