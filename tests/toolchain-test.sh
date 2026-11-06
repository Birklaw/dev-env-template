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

summary
