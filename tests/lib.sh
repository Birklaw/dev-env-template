#!/bin/bash
# Shared harness for the stub-driven tests.
#
# Nothing here touches the host: every privileged/network command the bootstrap
# uses (sudo, firewall-cmd, ip, systemctl, tailscale, docker) is replaced by a
# fake from tests/fakes/, and every path the code would write is redirected
# into $SANDBOX by the env overrides below. Run as a normal user; never sudo.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FAILS=0
TEST_CASES=0

sandbox_init() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  mkdir -p "$SANDBOX/bin" "$SANDBOX/etc"

  cp "$REPO_ROOT"/tests/fakes/* "$SANDBOX/bin/"
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"

  # Every dangerous command must resolve to the fake, or a test could touch the
  # real host. Fail loudly instead.
  local c
  for c in sudo systemctl docker firewall-cmd ip tailscale; do
    case "$(command -v "$c")" in
      "$SANDBOX/bin/$c") ;;
      *)
        echo "harness error: $c resolves to $(command -v "$c"), not the fake" >&2
        exit 1
        ;;
    esac
  done

  # Redirect every path the code writes.
  export DOCKER_FIREWALLD_ZONE_FILE="$SANDBOX/etc/docker.xml"
  # Nested and absent on purpose: exercises the "create /etc/docker" path.
  export DOCKER_DAEMON_JSON="$SANDBOX/etc/docker/daemon.json"
  export DOCKER_RESOLV_CONF="$SANDBOX/etc/resolv.conf"
  export CONTAINER_EGRESS_GUARD_SCRIPT="$SANDBOX/etc/guard"
  export CONTAINER_EGRESS_GUARD_UNIT="$SANDBOX/etc/guard.service"
  export CONTAINER_EGRESS_GUARD_TIMER="$SANDBOX/etc/guard.timer"

  printf 'nameserver 100.100.100.100\nnameserver 192.168.1.254\n' >"$DOCKER_RESOLV_CONF"
  printf '172.17.0.0/16 dev docker0 proto kernel scope link\n' >"$SANDBOX/ip.routes"
}

sandbox_cleanup() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# Run a lib/common.sh function in its own shell (the script calls `exit` on
# errors and expects the caller's `set -u`).
run_fn() {
  local name="$1"
  shift
  bash -c 'source "$1/lib/common.sh"; shift; "$@"' _ "$REPO_ROOT" "$name" "$@"
}

run_guard() {
  bash "$REPO_ROOT/lib/container-egress-guard.sh" "$@"
}

# ---- assertions ----
_ok() {
  TEST_CASES=$((TEST_CASES + 1))
}

fail() {
  _ok
  TEST_FAILS=$((TEST_FAILS + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

pass() {
  _ok
}

assert_eq() {
  if [ "$1" = "$2" ]; then pass; else fail "$3: expected [$2], got [$1]"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass ;;
    *) fail "$3: [$1] does not contain [$2]" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3: [$1] unexpectedly contains [$2]" ;;
    *) pass ;;
  esac
}

assert_file_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass; else fail "$3: $1 does not contain [$2]"; fi
}

# count_lines FILE PATTERN -> number of matching lines (0 if the file is absent)
count_lines() {
  local n=0
  [ -f "$1" ] && n="$(grep -c -- "$2" "$1" 2>/dev/null || true)"
  echo "${n:-0}"
}

assert_file_missing() {
  if [ -e "$1" ]; then fail "$3: $1 exists"; else pass; fi
}

summary() {
  printf '\n%s: %d checks, %d failures\n' "${0##*/}" "$TEST_CASES" "$TEST_FAILS"
  [ "$TEST_FAILS" -eq 0 ]
}
