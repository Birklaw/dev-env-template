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

# --- startup model defaults ------------------------------------------------
PI_DEFAULT_PROVIDER="venice"
PI_DEFAULT_MODEL="deepseek-v4-1-flash"
PI_DEFAULT_THINKING_MODEL="venice/deepseek-v4-1-flash"
PI_DEFAULT_THINKING_LEVEL="high"

# Writes the startup model into ~/.pi/agent/settings.json. This script is the
# single writer of that file (pi install above records each package in it), so
# the defaults are merged into what is there rather than replacing it: the
# package list, pi's own keys and any per-model thinking level already saved
# all survive. No-op when the values are already in place.
#
# Honoured only when the provider has credentials: pi falls back to the first
# authenticated model otherwise, so a fresh container without a venice login
# starts on something else rather than failing.
set_pi_startup_defaults() {
  local target="$HOME/.pi/agent/settings.json"

  if ! command -v node >/dev/null 2>&1; then
    echo "WARNING: node not on PATH; skipping Pi startup model defaults." >&2
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  node - "$target" "$PI_DEFAULT_PROVIDER" "$PI_DEFAULT_MODEL" \
    "$PI_DEFAULT_THINKING_MODEL" "$PI_DEFAULT_THINKING_LEVEL" <<'NODE'
const fs = require("node:fs");

const [target, provider, model, thinkingModel, thinkingLevel] = process.argv.slice(2);

let current = {};
if (fs.existsSync(target)) {
  const raw = fs.readFileSync(target, "utf8").trim();
  if (raw) {
    try {
      current = JSON.parse(raw);
    } catch {
      // Never overwrite a file pi owns with a guess: a bad settings.json is
      // pi's problem to report, and failing here would block container create.
      console.error(`WARNING: ${target} is not valid JSON; leaving it untouched.`);
      process.exit(0);
    }
  }
}

const merged = {
  ...current,
  defaultProvider: provider,
  defaultModel: model,
  modelThinkingLevels: {
    ...(current.modelThinkingLevels ?? {}),
    [thinkingModel]: thinkingLevel,
  },
};

// pi itself writes JSON.stringify(..., null, 2) with no trailing newline;
// matching that keeps re-runs from rewriting the file every time.
const next = JSON.stringify(merged, null, 2);
if (fs.existsSync(target) && fs.readFileSync(target, "utf8") === next) {
  console.log(`    [ok]   ${provider}/${model} (thinking ${thinkingLevel}) already set`);
  process.exit(0);
}
fs.writeFileSync(target, next);
console.log(`    [ok]   startup model ${provider}/${model}, thinking ${thinkingLevel}`);
NODE
}

set_pi_startup_defaults

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
