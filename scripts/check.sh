#!/bin/bash
# Repo check entry point: shell syntax and warnings, Python syntax, tests, and
# whitespace. The same command runs locally and in .github/workflows/tests.yml,
# so there is one thing to run and one contract to trust.
#
# Shellcheck runs at warning severity. The repo's info-level findings are
# deliberate (word-split iptables rules; a test whose literal "~/" value is the
# point), so they are not gated.
# shfmt is intentionally not run: its default style differs from 14 tracked
# scripts, and adopting it needs a separate, reviewable formatting commit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
mapfile -t scripts < <(git ls-files '*.sh')

echo "== bash -n (${#scripts[@]} scripts)"
for f in "${scripts[@]}"; do
  bash -n "$f" || fail=1
done

echo "== shellcheck (warnings and errors)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${scripts[@]}" || fail=1
else
  echo "   shellcheck not installed; skipped"
fi

echo "== python syntax"
python3 -m py_compile scripts/security-scan.py

echo "== tests"
./tests/run.sh || fail=1

echo "== whitespace"
git diff HEAD --check || fail=1

if [ "$fail" -eq 0 ]; then
  echo "== all checks passed"
else
  echo "== checks failed" >&2
fi
exit "$fail"
