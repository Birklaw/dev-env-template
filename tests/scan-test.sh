#!/bin/bash
# Unit checks for the scan's gate: the index must fail closed, the advisories
# it cannot place on the build's branch must surface, the accepted/new/stale
# classification and the --print-keys filter must behave, and a baseline that
# expects stdlib findings with no gated Go tool must refuse to go green.
# No network, no host state: the module is imported directly.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap sandbox_cleanup EXIT
sandbox_init

if PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/scripts/security-scan.py" "$SANDBOX" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("security_scan", sys.argv[1])
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
sandbox = pathlib.Path(sys.argv[2])

# stdlib_findings: a same-branch fix is a finding; a newer cross-branch fix and
# a missing fix are unevaluated; a sibling-branch entry must not leak.
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
assert not any(u[0] == "go1.26.10" and u[1] == "GO-2026-6603" for u in unevaluated), unevaluated

# load_accepted: the block is parsed, comments and blank lines are skipped.
doc = sandbox / "accepted.md"
doc.write_text(
    "intro\n<!-- security-scan-accepted\n"
    "# a comment\n\n"
    "stdlib|go1.26.1|GO-1\n"
    "direct|svc@1|GHSA-1\n"
    "-->\nend\n"
)
keys, found_block = scan.load_accepted(doc)
assert found_block, "block not found"
assert keys == {"stdlib|go1.26.1|GO-1", "direct|svc@1|GHSA-1"}, keys

# load_accepted: a missing block or file is "no baseline", not an error.
doc.write_text("nothing here\n")
keys, found_block = scan.load_accepted(doc)
assert not found_block and keys == set(), (found_block, keys)
keys, found_block = scan.load_accepted(sandbox / "missing.md")
assert not found_block and keys == set(), (found_block, keys)

# classify: the three sets partition the input.
seen, new, stale = scan.classify({"a", "b"}, {"b", "c"})
assert (seen, new, stale) == (["b"], ["a"], ["c"]), (seen, new, stale)

# missing_gated_input: only a baseline with stdlib keys and no gated version.
assert scan.missing_gated_input({"stdlib|go1.26.1|GO-1"}, set())
assert not scan.missing_gated_input({"stdlib|go1.26.1|GO-1"}, {"go1.26.1"})
assert not scan.missing_gated_input({"direct|svc@1|X"}, set())

# baseline_keys: module keys never enter the baseline.
mixed = {"stdlib|go1.26.1|GO-1", "module|k9s: m@v1|GO-2", "direct|svc@1|GHSA-1"}
assert scan.baseline_keys(mixed) == ["direct|svc@1|GHSA-1", "stdlib|go1.26.1|GO-1"], scan.baseline_keys(mixed)

# load_stdlib_index: a dead host and an empty index are both exit 2.
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
  fail 'scan gate unit checks'
fi

summary
