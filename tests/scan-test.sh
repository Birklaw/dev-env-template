#!/bin/bash
# Unit checks for the scan's stdlib gate: the index must fail closed, and the
# advisories it cannot place on the build's branch must surface instead of
# being dropped. No network, no host state: the module is imported directly.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap sandbox_cleanup EXIT
sandbox_init

if PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/scripts/security-scan.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("security_scan", sys.argv[1])
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

entry = {
    "path": "stdlib",
    "vulns": [
        {"id": "GO-2026-6603", "fixed": "1.26.9"},
        {"id": "GO-2026-6603", "fixed": "1.27.2"},
        {"id": "GO-2026-5856", "fixed": "1.27.0-rc.2"},
        {"id": "GO-9999-0001", "fixed": ""},
    ],
}
findings, unevaluated = scan.stdlib_findings(entry, ["go1.26.1", "go1.26.10"])
assert ("go1.26.1", "GO-2026-6603", "1.26.9") in findings, findings
assert any(u[1] == "GO-2026-5856" for u in unevaluated), unevaluated
assert any(u[1] == "GO-9999-0001" for u in unevaluated), unevaluated
assert all(u[1] != "GO-2026-6603" for u in unevaluated), unevaluated
# go1.26.10 already includes the 1.26.9 fix, so the sibling 1.27.2 entry must
# not surface it as unevaluated.
assert not any(u[0] == "go1.26.10" and u[1] == "GO-2026-6603" for u in unevaluated), unevaluated

original = scan.urllib.request.urlopen


def dead(*_args, **_kwargs):
    raise scan.urllib.error.URLError("dead host")


scan.urllib.request.urlopen = dead
try:
    scan.load_stdlib_index()
except SystemExit as exc:
    assert exc.code == 2, exc.code
else:
    raise AssertionError("load_stdlib_index did not exit 2")
finally:
    scan.urllib.request.urlopen = original

# A schema change (no stdlib entry) must also be exit 2, not an empty result.
scan.urllib.request.urlopen = lambda *_a, **_k: type(
    "R", (), {"__enter__": lambda s: s, "__exit__": lambda *a: None,
              "read": lambda s: b"[]", "__iter__": lambda s: iter([])}
)()
try:
    scan.load_stdlib_index()
except SystemExit as exc:
    assert exc.code == 2, exc.code
else:
    raise AssertionError("missing stdlib entry did not exit 2")
finally:
    scan.urllib.request.urlopen = original

print("scan unit checks ok")
PY
then
  pass
else
  fail 'scan stdlib gate unit checks'
fi

summary
