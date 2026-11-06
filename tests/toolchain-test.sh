#!/bin/bash
# Tests for the pinned-tool helpers in lib/common.sh and the skill-pack
# checkout swap in template/install-skills.sh. No network, no sudo.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap sandbox_cleanup EXIT
sandbox_init

echo '== devpod pin helpers'
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"

assert_eq "$(devpod_pin_sha x86_64)" "$DEVPOD_SHA256_AMD64" 'devpod sha x86_64'
assert_eq "$(devpod_pin_sha aarch64)" "$DEVPOD_SHA256_ARM64" 'devpod sha aarch64'
assert_eq "$(devpod_pin_sha arm64)" "$DEVPOD_SHA256_ARM64" 'devpod sha arm64'
if devpod_pin_sha armv7l >/dev/null 2>&1; then
  fail 'devpod sha armv7l should be rejected'
else
  pass
fi
assert_contains "$(devpod_pin_url x86_64)" "$DEVPOD_VERSION/devpod-linux-amd64" 'devpod url x86_64'
assert_contains "$(devpod_pin_url aarch64)" "$DEVPOD_VERSION/devpod-linux-arm64" 'devpod url aarch64'
if devpod_pin_url riscv64 >/dev/null 2>&1; then
  fail 'devpod url riscv64 should be rejected'
else
  pass
fi

echo '== ensure_checkout keeps the previous tree on failure'
export CHECKOUT_ROOT="$SANDBOX/checkouts"
export SKILLS_HOME="$SANDBOX/agents"
# shellcheck source=template/install-skills.sh
. "$REPO_ROOT/template/install-skills.sh"
set +e # install-skills.sh enables -e; the harness collects failures instead

src="$SANDBOX/src"
mkdir -p "$src"
git -C "$src" init -q
git -C "$src" config user.email test@example.com
git -C "$src" config user.name test
printf 'one\n' >"$src/file"
git -C "$src" add file
git -C "$src" commit -qm one
sha1="$(git -C "$src" rev-parse HEAD)"
printf 'two\n' >>"$src/file"
git -C "$src" commit -qam two
sha2="$(git -C "$src" rev-parse HEAD)"

ensure_checkout pack "$src" "$sha1" >/dev/null 2>&1
assert_eq "$?" "0" 'initial checkout exits 0'
assert_eq "$(git -C "$CHECKOUT_ROOT/pack" rev-parse HEAD 2>/dev/null)" "$sha1" 'initial checkout'

ensure_checkout pack "$src" "$sha2" >/dev/null 2>&1
assert_eq "$?" "0" 're-pin exits 0'
assert_eq "$(git -C "$CHECKOUT_ROOT/pack" rev-parse HEAD 2>/dev/null)" "$sha2" 're-pin to a new commit'

if (ensure_checkout pack "$src" 0000000000000000000000000000000000000000) >/dev/null 2>&1; then
  fail 'ensure_checkout with a missing commit should fail'
else
  pass
fi
assert_eq "$(git -C "$CHECKOUT_ROOT/pack" rev-parse HEAD 2>/dev/null)" "$sha2" 'previous tree survives a failed re-pin'
assert_eq "$(find "$CHECKOUT_ROOT" -maxdepth 1 -name '.checkout.*' | wc -l | tr -d ' ')" "0" 'no temp checkout left behind'

summary
