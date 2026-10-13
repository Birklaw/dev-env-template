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

# ---------- host locale ----------
# devpod's ssh transport forwards the client's LANG/LC_* (ssh_config
# SendEnv) into every container shell. The base image ships only C.UTF-8,
# so each one prints "setlocale: LC_ALL: cannot change locale
# (en_IE.UTF-8)" on every ssh command and herdr machine hop. Generate the
# host's locale once; locale-gen lives in the locales package, which
# minimal base images strip. Revisit the pinned locale if the host's
# locale ever changes.
if ! locale -a 2>/dev/null | grep -qi 'en_IE.utf8'; then
  echo "==> Generating en_IE.UTF-8 locale..."
  command -v locale-gen &>/dev/null || $APT install "${APT_OPTS[@]}" locales </dev/null
  sudo locale-gen en_IE.UTF-8 >/dev/null
  echo "==> en_IE.UTF-8 generated."
else
  echo "==> en_IE.UTF-8 already present."
fi

# ---------- base toolchain (mise + global tools) ----------
bash "$REPO_ROOT/setup-mise.sh"

# setup-mise.sh ran in a subshell; re-add mise to PATH for what follows.
export PATH="$HOME/.local/bin:$PATH"

# ---------- skill packs for Pi ----------
# Pi is installed above; this installs the configured skill packs into
# ~/.agents/skills so Pi discovers them in every project. Mirrors the host
# bootstrap step.
bash "$REPO_ROOT/install-skills.sh"

# ---------- Pi packages (providers) ----------
# Provider extensions declared in install-pi-packages.sh. Mirrors the host
# bootstrap step.
bash "$REPO_ROOT/install-pi-packages.sh"

# ---------- project-level mise.toml (if present) ----------
# Resilience over fail-closed here: a bad project pin or a transient network
# failure must not wedge `devpod up`. Warn loudly and let the container come up
# on the global toolchain; the user can rerun `mise install` once fixed.
MISE_TOML=""
for candidate in ./mise.toml ../mise.toml ../../mise.toml; do
  if [[ -f "$candidate" ]]; then
    MISE_TOML="$candidate"
    break
  fi
done
if [[ -n "$MISE_TOML" ]]; then
  echo "==> Found $MISE_TOML, installing project-specific tools..."
  if ! mise trust "$MISE_TOML" || ! mise install; then
    echo "WARNING: project tool install failed for $MISE_TOML." >&2
    echo "         The container is up on the global toolchain; any project" >&2
    echo "         pin that did not install is missing. Once the cause is" >&2
    echo "         fixed (network, bad version), rerun:" >&2
    echo "           mise trust $MISE_TOML && mise install" >&2
  fi
fi

echo "==> Dev environment ready."
