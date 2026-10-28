#!/bin/bash
# Run every stub-driven test (no sudo, no host mutation).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
status=0
for t in *-test.sh; do
  [ -x "$t" ] || continue
  echo "### $t"
  "./$t" || status=1
done
exit "$status"
