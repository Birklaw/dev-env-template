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
  * with --deep, every module recorded in each installed Go binary

It prints a manual checklist for the pins OSV cannot cover (node/python/neovim
runtimes, devcontainer features, skill packs, the base image).

Usage:
  scripts/security-scan.py [--deep] [--warn-only] [--dotfiles PATH]

Exit status: 0 clean, 1 findings, 2 the scan could not run (network).
Requires only python3 (stdlib) and the repo; mise/go are used when present.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OSV_BATCH = "https://api.osv.dev/v1/querybatch"
VULN_GO_INDEX = "https://vuln.go.dev/index/modules.json"

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
MANUAL_PINS = {
    "node": "https://nodejs.org/en/blog/vulnerability",
    "python": "https://www.python.org/news/security/",
    "go": "https://go.dev/security/vulndb",
    "neovim": "https://github.com/neovim/neovim/security/advisories",
    "herdr": "upstream releases (no OSV ecosystem)",
}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


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
    for m in re.finditer(r'install_pi_package\s+"(npm|git):([^"@]+)@([^"]+)"', path.read_text()):
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
    for i in range(0, len(queries), 500):
        payload = json.dumps({"queries": queries[i:i + 500]}).encode()
        req = urllib.request.Request(OSV_BATCH, data=payload,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.load(resp)
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"ERROR: OSV query failed: {exc}", file=sys.stderr)
            sys.exit(2)
        results.extend(body.get("results", []))
    return results


def go_tuple(v: str):
    nums = [int(x) for x in re.findall(r"\d+", v)[:3]]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)


def stdlib_findings(go_versions):
    """Return [(go_version, vuln_id, fixed)] for advisories on the same branch."""
    try:
        with urllib.request.urlopen(VULN_GO_INDEX, timeout=60) as resp:
            index = json.load(resp)
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"WARNING: could not fetch {VULN_GO_INDEX}: {exc}", file=sys.stderr)
        return []
    entry = next((e for e in index if e.get("path") == "stdlib"), None)
    if not entry:
        return []
    findings = []
    for gover in go_versions:
        gnums = go_tuple(gover)
        for vuln in entry.get("vulns", []):
            fixed = vuln.get("fixed") or ""
            if not fixed:
                continue
            fnums = go_tuple(fixed)
            if fnums[:2] != gnums[:2]:
                continue  # different release branch; not this build
            if gnums < fnums:
                findings.append((gover, vuln["id"], fixed))
    return findings


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
            parts = line.split("\t")
            if len(parts) >= 3 and parts[0] == "dep" and parts[2].startswith("v"):
                deps.append((parts[1], parts[2]))
        bins[name] = (path, gover, deps)
    return bins


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deep", action="store_true",
                    help="also scan every module recorded in the Go binaries")
    ap.add_argument("--warn-only", action="store_true",
                    help="always exit 0; report findings without failing")
    ap.add_argument("--dotfiles", default=str(REPO.parent / "dotfiles"))
    args = ap.parse_args()

    setup_mise = REPO / "template" / "setup-mise.sh"
    if not setup_mise.exists():
        print(f"ERROR: {setup_mise} not found", file=sys.stderr)
        return 2

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

    results = osv_batch(queries) if queries else []
    hits = 0
    print("== direct pins")
    for label, result in zip(labels, results):
        vulns = result.get("vulns", [])
        if vulns:
            hits += 1
            ids = ", ".join(v["id"] for v in vulns)
            print(f"HIT  {label} -> {ids}")
        else:
            print(f"OK   {label}")

    print("\n== Go stdlib / build versions")
    bins = go_binaries(mise_json)
    go_versions = sorted({b[1] for b in bins.values() if b[1]})
    if not bins:
        print("(no installed Go tools found; run `mise install` first)")
    for name, (_, gover, _) in sorted(bins.items()):
        print(f"     {name:12s} {gover or 'unknown build version'}")
    by_version = {}
    for gover, vid, fixed in stdlib_findings(go_versions):
        by_version.setdefault(gover, []).append((vid, fixed))
    for gover in sorted(by_version):
        items = by_version[gover]
        newest = max(fixed for _, fixed in items)
        hits += len(items)
        print(f"HIT  {gover}: {len(items)} stdlib advisory(ies), newest fix {newest}")
        if args.deep:
            for vid, fixed in sorted(items):
                print(f"       {vid} (fixed {fixed})")

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
        dep_results = osv_batch(dep_queries) if dep_queries else []
        for label, result in zip(dep_labels, dep_results):
            vulns = result.get("vulns", [])
            if vulns:
                hits += 1
                print(f"HIT  {label} -> {', '.join(v['id'] for v in vulns)}")

    print("\n== manual upstream checks")
    for item in manual:
        print(f"     {item}")
    print("     devcontainer features  pinned in template/.devcontainer/devcontainer.json")
    print("     skill packs            pinned to commit SHAs in template/install-skills.sh")
    print("     base image             ubuntu-24.04 tag; track Microsoft's image updates")

    print(f"\n{hits} finding(s).")
    if hits and not args.warn_only:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
