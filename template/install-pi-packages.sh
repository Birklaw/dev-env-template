#!/bin/bash
# Pi package installer — shared by the host bootstrap (lib/common.sh
# run_toolchain_install) and every devcontainer (.devcontainer/post-create.sh).
#
# Installs the Pi packages (providers/extensions) declared below. Pi keeps each
# package under ~/.pi/agent/ and records its source in ~/.pi/agent/settings.json;
# nothing is vendored into this repo. Credentials are NOT installed here — they
# live in ~/.pi/agent/auth.json at runtime (see the closing note).
#
# ADDING / REMOVING A PACKAGE: add or delete one install_pi_package line below.
# Pin git sources to a commit SHA (immutable — a tag can be moved) and npm
# sources to an exact version, with the human-readable release as a trailing
# comment. `pi update --extensions` reconciles installations; pinned refs do
# not move on their own, so bump them deliberately.
set -euo pipefail

# Pi is installed by setup-mise.sh, but its shim is not on PATH in a
# non-interactive shell. Add the mise shims and the mise/pi bin dir.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

log() { echo "==> $*"; }

if ! command -v pi >/dev/null 2>&1; then
  echo "ERROR: pi not found on PATH; run setup-mise.sh first." >&2
  exit 1
fi

install_pi_package() {
  local source="$1"
  log "Installing Pi package $source..."
  pi install "$source"
}

# --- packages --------------------------------------------------------------
# One line per package. Source syntax: npm:<name>@<version> or
# git:<host>/<path>@<commit-sha>. The trailing comment is the release pinned.

install_pi_package "npm:pi-ppq@0.1.1"                                                  # pi-ppq 0.1.1
install_pi_package "git:github.com/Kilo-Org/kilo-pi-provider@0be983e9875a56e0000030d42aec4ce264002a38"  # kilo-pi-provider v2026.09.3

# pi-venice stays on 0.2.0 deliberately. 0.2.0 is byte-identical to the
# audited public commit; 0.3.0 (npm `next`) adds a hand-rolled E2EE transport
# whose sources (e2ee.ts, reasoning.ts, transport.ts) exist only in the
# published tarball, and whose "attestation" is an unverified `verified: true`
# the server sends about itself. Re-audit those files before bumping.
install_pi_package "npm:pi-venice@0.2.0"                                               # pi-venice 0.2.0

# --- credentials (not installed) -------------------------------------------
cat <<'EOF'

==> Pi packages installed. Credentials are NOT provisioned by this setup:
    - Kilo:    free models work signed-out; run /login kilo (or set
               KILO_API_KEY) to unlock the full catalog.
    - PayPerQ: run /login and choose PayPerQ (or set PPQ_API_KEY).
    - Venice:  run /login venice and paste the key, or put the key in the
               environment AND set "pi-venice": {"apiKeyEnv":
               "$VENICE_API_KEY"} in ~/.pi/agent/settings.json. The bare
               VENICE_API_KEY variable alone is NOT enough: pi-venice
               registers the literal name "VENICE_API_KEY" as the key, so
               chat requests go out as `Authorization: Bearer
               VENICE_API_KEY` and Venice answers 401. Note the `$`.
    Credentials live in ~/.pi/agent/auth.json. A devcontainer's home is
    ephemeral, so re-authenticate after a recreate, or supply the keys
    through the environment.

EOF
