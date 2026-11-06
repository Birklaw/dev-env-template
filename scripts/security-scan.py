#!/usr/bin/env python3
"""Two-weekly supply-chain scan for the toolchain pins.

Mirrors the 14-day minimum-release-age cadence: the gate delays a bad release,
this scan detects a known advisory that the delay cannot help with (an older
pin, or a fix published inside the window).

What it checks against OSV (https://osv.dev):
  * mise tool pins parsed from template/setup-mise.sh, resolved to the version
    actually installed where mise knows it
  * Pi packages from template/install-pi-packages.sh
  * chrome-devtools-mcp from the dotfiles pi/mcp.json
  * the Go stdlib of each installed Go tool, against the Go vuln DB index
  * the installed Mason tools (nvim/lua/mason-tools.lua): npm and pip
    manifests, plus every Go-built binary's modules and stdlib build version
  * with --deep, every module recorded in each installed Go binary

It prints a manual checklist for the pins OSV cannot cover (node/python/neovim
runtimes, devcontainer features, skill packs, the base image, and Mason tools
that ship no machine-readable manifest).

Usage:
  scripts/security-scan.py [--deep] [--warn-only] [--dotfiles PATH] [--mason DIR]

Exit status: 0 clean, 1 findings, 2 the scan could not run (missing tools,
network, or an unusable feed).
Requires python3 (stdlib), mise, and go: mise resolves the installed toolchain
and go reads the binaries' build metadata. A missing tool is exit 2, not a
finding.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OSV_BATCH = "https://api.osv.dev/v1/querybatch"
VULN_GO_INDEX = "https://vuln.go.dev/index/modules.json"
MASON_DEFAULT = Path.home() / ".local/share/nvim/mason/packages"

# name in setup-mise.sh -> (ecosystem, OSV package, version transform)
GO_TOOLS = {
    "helm": ("helm.sh/helm/v4", lambda v: "v" + v),
    "k9s": ("github.com/derailed/k9s", lambda v: "v" + v),
    "kubectl": ("k8s.io/kubectl", lambda v: "v0." + ".".join(v.split(".")[1:])),
    "terraform": ("github.com/hashicorp/terraform", lambda v: "v" + v),
    "flux2": ("github.com/fluxcd/flux2/v2", lambda v: "v" + v),
    "sops": ("github.com/getsops/sops/v3", lambda v: "v" + v),
    "lazygit": ("github.com/jesseduffield/lazygit", lambda v: "v" + v),
    "fzf": ("github.com/junegunn/fzf", lambda v: "v" + v),
    "github:home-operations/flate": ("github.com/home-operations/flate", lambda v: "v" + v),
}
# tool key -> installed executable name, where it differs from the tool name
GO_EXE = {"flux2": "flux", "github:home-operations/flate": "flate"}
NPM_PINS = {
    "pnpm": "pnpm",
    "@earendil-works/pi-coding-agent": "@earendil-works/pi-coding-agent",
    "pi-ppq": "pi-ppq",
    "pi-venice": "pi-venice",
    "chrome-devtools-mcp": "chrome-devtools-mcp",
}
PYPI_PINS = {"uv": "uv"}
CRATE_PINS = {"ripgrep": "ripgrep", "fd": "fd-find", "tree-sitter": "tree-sitter"}
# OSV has no ecosystem for these; they get a manual upstream check.
# value is the upstream advisory/release page; these have no OSV ecosystem
MANUAL_PINS = {
    "node": "https://nodejs.org/en/blog/vulnerability",
    "python": "https://www.python.org/news/security/",
    "go": "https://go.dev/security/vulndb",
    "neovim": "https://github.com/neovim/neovim/security/advisories",
    "herdr": "https://github.com/herdrdev/herdr/releases",
}


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except FileNotFoundError:
        # The preflight in main() covers the normal case; this keeps a PATH
        # race from becoming a traceback (exit 1, i.e. "findings").
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: not found")


def missing_tools(which=shutil.which):
    """Required executables not on PATH; the scan cannot gate without them."""
    return [tool for tool in ("mise", "go") if which(tool) is None]


def logical_lines(path: Path):
    """Join backslash continuations and drop full-line comments."""
    out, buf = [], ""
    for raw in path.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        buf = f"{buf} {s}".strip() if buf else s
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
            continue
        out.append(buf)
        buf = ""
    if buf:
        out.append(buf)
    return out


def parse_pin(token: str):
    """Return (kind, name, version) for a mise tool token, or None."""
    if token.startswith("npm:"):
        name, _, ver = token[4:].rpartition("@")
        return ("npm", name, ver) if name and ver else None
    if token.startswith("github:"):
        name, _, ver = token[7:].rpartition("@")
        return ("github", name, ver) if name and ver else None
    if "@" in token:
        name, _, ver = token.rpartition("@")
        return ("mise", name, ver) if name and ver else None
    return None


def mise_pins(setup_mise: Path):
    pins = []
    for line in logical_lines(setup_mise):
        if not line.startswith("mise use -g"):
            continue
        for token in shlex.split(line[len("mise use -g"):]):
            pin = parse_pin(token)
            if pin:
                pins.append(pin)
    return pins


def pi_packages(path: Path):
    pins = []
    if not path.exists():
        return pins
    for m in re.finditer(r'install_pi_package\s+"(npm|git):(.+)@([^"]+)"', path.read_text()):
        pins.append((m.group(1), m.group(2), m.group(3)))
    return pins


def mcp_package(dotfiles: Path):
    path = dotfiles / "pi" / "mcp.json"
    if not path.exists():
        return None
    m = re.search(r"chrome-devtools-mcp@([0-9][^\"\s]*)", path.read_text())
    return ("npm", "chrome-devtools-mcp", m.group(1)) if m else None


def resolve_mise(mise_json: dict, name: str) -> str | None:
    entries = mise_json.get(name) or []
    for entry in entries:
        if entry.get("active"):
            return entry.get("version")
    if entries:
        return entries[-1].get("version")
    return None


def osv_batch(queries):
    results = []
    for i in range(0, len(queries), 1000):
        payload = json.dumps({"queries": queries[i:i + 1000]}).encode()
        req = urllib.request.Request(OSV_BATCH, data=payload,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.load(resp)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            print(f"ERROR: OSV query failed: {exc}", file=sys.stderr)
            sys.exit(2)
        results.extend(body.get("results", []))
    return results


def go_tuple(v: str):
    nums = [int(x) for x in re.findall(r"\d+", v)[:3]]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)


def load_stdlib_index():
    """Fetch and validate the Go stdlib index.

    A failed fetch or a schema change is exit 2, not an empty result: an empty
    result would make the gate green having checked nothing.
    """
    try:
        with urllib.request.urlopen(VULN_GO_INDEX, timeout=60) as resp:
            index = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not fetch {VULN_GO_INDEX}: {exc}", file=sys.stderr)
        sys.exit(2)
    entry = next((e for e in index if e.get("path") == "stdlib"), None)
    if not entry or not entry.get("vulns"):
        print(f"ERROR: {VULN_GO_INDEX} has no usable stdlib entry; refusing to "
              "report a green gate", file=sys.stderr)
        sys.exit(2)
    return entry


def stdlib_findings(entry, go_versions):
    """Return (findings, unevaluated) for the installed Go versions.

    findings: [(gover, vuln_id, fixed)] resolved on the build's own branch.
    unevaluated: [(gover, vuln_id, reason)] with no branch-local fix the index
    can use; they are reported but never gate.
    """
    by_id = {}
    for vuln in entry.get("vulns", []):
        by_id.setdefault(vuln["id"], []).append(vuln.get("fixed") or "")
    findings, unevaluated = [], []
    for gover in go_versions:
        gnums = go_tuple(gover)
        for vid, fixes in sorted(by_id.items()):
            nonempty = [f for f in fixes if f]
            if not nonempty:
                unevaluated.append((gover, vid, "no fixed version recorded"))
                continue
            same = [(f, go_tuple(f)) for f in nonempty if go_tuple(f)[:2] == gnums[:2]]
            if any(fn <= gnums for _, fn in same):
                continue  # fixed on this branch at or before the build
            newer_same = sorted((fn, f) for f, fn in same if fn > gnums)
            if newer_same:
                findings.append((gover, vid, newer_same[0][1]))
                continue
            newer_any = sorted((go_tuple(f), f) for f in nonempty if go_tuple(f) > gnums)
            if newer_any:
                unevaluated.append((gover, vid, f"fix {newer_any[0][1]} is on another branch"))
            # else: every known fix predates the build; already fixed
    return findings, unevaluated


def go_binaries(mise_json: dict):
    """Map tool name -> (path, go version, [(module, version)])."""
    bins = {}
    for name in GO_TOOLS:
        exe = GO_EXE.get(name, name)
        path = run(["mise", "which", exe]).stdout.strip()
        if not path:
            entries = mise_json.get(name) or []
            if entries:
                candidate = Path(entries[-1].get("install_path", "")) / exe
                if candidate.exists():
                    path = str(candidate)
        if not path:
            continue
        out = run(["go", "version", "-m", path]).stdout
        m = re.match(r"^.*: (go[0-9][^\s]*)", out)
        gover = m.group(1) if m else None
        deps = []
        for line in out.splitlines():
            parts = line.strip().split("\t")
            if len(parts) >= 3 and parts[0] == "dep" and parts[2].startswith("v"):
                deps.append((parts[1], parts[2]))
        bins[name] = (path, gover, deps)
    return bins


def read_pkg_json(path: Path):
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    name, version = data.get("name"), data.get("version")
    return (str(name), str(version)) if name and version else None


def read_metadata(path: Path):
    name = version = None
    try:
        with path.open() as fh:
            for line in fh:
                if not line.strip():
                    break
                low = line.lower()
                if low.startswith("name:"):
                    name = line.split(":", 1)[1].strip()
                elif low.startswith("version:"):
                    version = line.split(":", 1)[1].strip()
                if name and version:
                    break
    except OSError:
        return None
    return (name, version) if name and version else None


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def go_build_info(path: Path):
    try:
        out = subprocess.run(["go", "version", "-m", str(path)],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"^.*: (go[0-9][^\s]*)", out)
    if not m:
        return None
    deps = []
    for line in out.splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 3 and parts[0] == "dep" and parts[2].startswith("v"):
            deps.append((parts[1], parts[2]))
    return m.group(1), deps


def scan_mason(root: Path):
    """Inspect installed Mason packages: npm/pip manifests and Go binaries.

    Returns the unique package versions to query, the Go binaries with their
    build info, and the package dirs that expose no machine-readable version.
    """
    npm, pip, go = {}, {}, {}
    topdirs, covered = set(), set()
    go_missing = shutil.which("go") is None
    if not root.is_dir():
        return {"packages": 0, "npm": npm, "pip": pip, "go": go,
                "manual": [], "go_missing": go_missing}
    for dirpath, _dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        top = rel.split(os.sep)[0] if rel != "." else ""
        if top:
            topdirs.add(top)
        for fn in filenames:
            p = Path(dirpath) / fn
            sp = str(p)
            if fn == "package.json" and f"{os.sep}node_modules{os.sep}" in sp:
                pv = read_pkg_json(p)
                if pv:
                    npm[pv] = True
                    covered.add(top)
            elif fn == "METADATA" and dirpath.endswith(".dist-info"):
                pv = read_metadata(p)
                if pv:
                    pip[pv] = True
                    covered.add(top)
            elif "node_modules" not in sp and os.access(p, os.X_OK) and is_elf(p):
                info = go_build_info(p)
                if info:
                    go[sp] = info
                    covered.add(top)
    return {
        "packages": len(topdirs),
        "npm": npm,
        "pip": pip,
        "go": go,
        "manual": sorted(topdirs - covered),
        "go_missing": go_missing,
    }


def finding_key(section: str, identity: str, vid: str) -> str:
    return f"{section}|{identity}|{vid}"


def load_accepted(path: Path):
    """Parse the security-scan-accepted block; return (keys, block_found)."""
    if not path.exists():
        return set(), False
    m = re.search(r"<!--\s*security-scan-accepted\s*\n(.*?)-->", path.read_text(), re.S)
    if not m:
        return set(), False
    accepted = set()
    for line in m.group(1).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            accepted.add(line)
    return accepted, True


def classify(found, accepted):
    """Split finding keys into (accepted_seen, new, stale), each sorted."""
    return sorted(found & accepted), sorted(found - accepted), sorted(accepted - found)


def missing_gated_input(accepted, gated_versions):
    """True when the baseline expects stdlib findings but no gated Go tool ran."""
    return any(k.startswith("stdlib|") for k in accepted) and not gated_versions


def baseline_keys(found):
    """Keys --print-keys emits: the baseline covers CI-visible sections only.

    Module keys come from --deep, which the scheduled scan does not run, so a
    baseline regenerated with --print-keys must not carry them.
    """
    return sorted(k for k in found if not k.startswith("module|"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deep", action="store_true",
                    help="also scan every module recorded in the Go binaries")
    ap.add_argument("--warn-only", action="store_true",
                    help="always exit 0; report findings without failing")
    ap.add_argument("--accepted", default=str(REPO / "SECURITY.md"),
                    help="file holding the security-scan-accepted block")
    ap.add_argument("--no-accepted", action="store_true",
                    help="treat every finding as new (strict)")
    ap.add_argument("--print-keys", action="store_true",
                    help="print the current finding keys and exit 0")
    ap.add_argument("--dotfiles", default=str(REPO.parent / "dotfiles"))
    ap.add_argument("--mason", default=str(MASON_DEFAULT),
                    help="Mason packages dir (default: ~/.local/share/nvim/mason/packages)")
    args = ap.parse_args()

    setup_mise = REPO / "template" / "setup-mise.sh"
    if not setup_mise.exists():
        print(f"ERROR: {setup_mise} not found", file=sys.stderr)
        return 2

    missing = missing_tools()
    if missing:
        print(f"ERROR: missing required tool(s): {', '.join(missing)}; "
              "the gate needs mise and go on PATH", file=sys.stderr)
        return 2

    accepted = set()
    if not args.no_accepted:
        accepted, have_block = load_accepted(Path(args.accepted))
        if not have_block:
            print(f"WARNING: no security-scan-accepted block in {args.accepted}; "
                  "treating every finding as new", file=sys.stderr)

    mise_json = {}
    out = run(["mise", "ls", "--json"]).stdout
    if out:
        try:
            mise_json = json.loads(out)
        except json.JSONDecodeError:
            pass

    queries, labels = [], []

    def add(label, ecosystem, name, version):
        if not version:
            return
        queries.append({"package": {"name": name, "ecosystem": ecosystem},
                        "version": version})
        labels.append(label)

    manual = []
    for kind, name, pin in mise_pins(setup_mise):
        if kind == "npm":
            key, lookup = f"npm:{name}", name
        elif kind == "github":
            key, lookup = f"github:{name}", f"github:{name}"
        else:
            key, lookup = name, name
        resolved = resolve_mise(mise_json, key)
        version = resolved or pin
        label = f"{name}@{version}"
        if lookup in GO_TOOLS and kind in ("mise", "github"):
            module, transform = GO_TOOLS[lookup]
            try:
                add(label, "Go", module, transform(version))
            except (IndexError, ValueError):
                manual.append(f"{label:32s} (could not map to a Go module version)")
        elif name in NPM_PINS:
            add(label, "npm", NPM_PINS[name], version)
        elif name in PYPI_PINS:
            add(label, "PyPI", PYPI_PINS[name], version)
        elif name in CRATE_PINS:
            add(label, "crates.io", CRATE_PINS[name], version)
        elif name in MANUAL_PINS:
            manual.append(f"{label:32s} {MANUAL_PINS[name]}")
        else:
            manual.append(f"{label:32s} (no OSV mapping; check upstream)")

    for kind, name, version in pi_packages(REPO / "template" / "install-pi-packages.sh"):
        if kind == "npm":
            add(f"{name}@{version}", "npm", name, version)
        else:
            manual.append(f"{name}@{version[:12]} (git commit; review upstream)")

    mcp = mcp_package(Path(args.dotfiles))
    if mcp:
        add(f"{mcp[1]}@{mcp[2]}", "npm", mcp[1], mcp[2])
    else:
        manual.append("chrome-devtools-mcp (dotfiles pi/mcp.json not found)")

    mason_dir = Path(args.mason).expanduser()
    mason = scan_mason(mason_dir)
    mason_queries, mason_labels = [], []
    for name, version in sorted(mason["npm"]):
        mason_queries.append({"package": {"name": name, "ecosystem": "npm"},
                              "version": version})
        mason_labels.append(f"npm {name}@{version}")
    for name, version in sorted(mason["pip"]):
        mason_queries.append({"package": {"name": name, "ecosystem": "PyPI"},
                              "version": version})
        mason_labels.append(f"PyPI {name}@{version}")

    all_queries = queries + mason_queries
    results = osv_batch(all_queries) if all_queries else []
    direct_results = results[:len(queries)]
    mason_results = results[len(queries):]
    found = set()
    mason_hits = 0
    print("== direct pins")
    for label, result in zip(labels, direct_results):
        vulns = result.get("vulns", [])
        if vulns:
            ids = [v["id"] for v in vulns]
            found.update(finding_key("direct", label, vid) for vid in ids)
            print(f"HIT  {label} -> {', '.join(ids)}")
        else:
            print(f"OK   {label}")

    if mason["packages"]:
        print(f"\n== Mason tools ({mason_dir})")
        print(f"     {mason['packages']} packages; {len(mason['npm'])} unique npm "
              f"versions, {len(mason['pip'])} pip, {len(mason['go'])} Go binary(ies)")
        if mason["manual"]:
            print(f"     no machine-readable manifest (manual): {', '.join(mason['manual'])}")
        if mason["go_missing"]:
            print("     go not on PATH: Go binaries under Mason were not inspected")
        print("     (versions are the package's own tree, mostly transitive; verify reachability)")
        clean = 0
        for label, result in zip(mason_labels, mason_results):
            vulns = result.get("vulns", [])
            if vulns:
                mason_hits += 1
                print(f"HIT  {label} -> {', '.join(v['id'] for v in vulns)} (report-only)")
            else:
                clean += 1
        print(f"     clean: {clean}")

    print("\n== Go stdlib / build versions")
    bins = go_binaries(mise_json)
    for path, (gover, deps) in mason["go"].items():
        label = f"mason:{Path(path).parent.name or Path(path).name}"
        bins[label] = (path, gover, deps)
    go_versions = sorted({b[1] for b in bins.values() if b[1]})
    if not bins:
        print("(no installed Go tools found; run `mise install` first)")
    for name, (_, gover, _) in sorted(bins.items()):
        print(f"     {name:12s} {gover or 'unknown build version'}")
    unevaluated = []
    by_version = {}
    if go_versions:
        stdlib_entry = load_stdlib_index()
        findings, unevaluated = stdlib_findings(stdlib_entry, go_versions)
        for gover, vid, fixed in findings:
            by_version.setdefault(gover, []).append((vid, fixed))
    gated_versions = {b[1] for name, b in bins.items()
                      if b[1] and not name.startswith("mason:")}
    if missing_gated_input(accepted, gated_versions):
        print("ERROR: the baseline expects stdlib findings but no gated Go tool "
              "resolved; refusing to report a green gate", file=sys.stderr)
        return 2
    for gover in sorted(by_version):
        items = by_version[gover]
        newest = max(fixed for _, fixed in items)
        report_only = gover not in gated_versions
        if report_only:
            mason_hits += len(items)
        else:
            found.update(finding_key("stdlib", gover, vid) for vid, _ in items)
        suffix = " (report-only)" if report_only else ""
        print(f"HIT  {gover}: {len(items)} stdlib advisory(ies), newest fix {newest}{suffix}")
    if unevaluated:
        print("     UNEVALUATED stdlib advisory(ies); check the full advisory:")
        for gover in sorted({u[0] for u in unevaluated}):
            items = sorted({(u[1], u[2]) for u in unevaluated if u[0] == gover})
            suffix = "" if gover in gated_versions else " (report-only)"
            print(f"       {gover}: {len(items)} candidate(s){suffix}")
            if gover in gated_versions:
                for vid, reason in items:
                    print(f"         {vid}: {reason}")

    if args.deep:
        print("\n== Go binary modules (module-level, verify reachability)")
        dep_queries, dep_labels = [], []
        for name, (_, _, deps) in bins.items():
            for module, version in deps:
                if module == "stdlib":
                    continue
                dep_queries.append({"package": {"name": module, "ecosystem": "Go"},
                                    "version": version})
                dep_labels.append(f"{name}: {module}@{version}")
        print(f"     {len(dep_queries)} module query(ies)")
        dep_results = osv_batch(dep_queries) if dep_queries else []
        for label, result in zip(dep_labels, dep_results):
            vulns = result.get("vulns", [])
            if vulns:
                ids = [v["id"] for v in vulns]
                text = f"{label} -> {', '.join(ids)}"
                if label.startswith("mason:"):
                    mason_hits += 1
                    print(f"HIT  {text} (report-only)")
                else:
                    found.update(finding_key("module", label, vid) for vid in ids)
                    print(f"HIT  {text}")

    print("\n== manual upstream checks")
    for item in manual:
        print(f"     {item}")
    print("     devcontainer features  pinned in template/.devcontainer/devcontainer.json")
    print("     skill packs            pinned to commit SHAs in template/install-skills.sh")
    print("     base image             ubuntu-24.04 tag; track Microsoft's image updates")

    accepted_seen, new, stale = classify(found, accepted)
    print(f"\naccepted: {len(accepted_seen)}  new: {len(new)}  stale: {len(stale)}"
          f"  unevaluated: {len(set(unevaluated))}  (mason report-only: {mason_hits})")
    for k in new:
        print(f"NEW    {k}")
    for k in stale:
        print(f"STALE  {k} (no longer reported; remove from {args.accepted} if the risk is gone)")
    if args.print_keys:
        print("\n-- keys --")
        for k in baseline_keys(found):
            print(k)
        return 0
    if new and not args.warn_only:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
