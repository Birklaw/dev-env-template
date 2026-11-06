# Security

This file is the durable record for the toolchain's supply-chain policy and
for deliberate exceptions to it. Decisions that would otherwise live only in a
shell history or a chat belong here.

## Policy

The default is a **14-day minimum release age**:

| Manager | Setting | Location |
| --- | --- | --- |
| mise | `minimum_release_age = "14d"` | `~/.config/mise/config.toml`, set by `template/setup-mise.sh` |
| npm | `min-release-age=14` | dotfiles `.npmrc` |
| pnpm | `minimumReleaseAge: 20160` | dotfiles `pnpm.config.yaml` |
| uv | `exclude-newer = "14 days"` | dotfiles `uv.toml` |

A floating pin (`node@24`, `uv@0.13`) cannot resolve to a version younger than
the window. Exact versions and `mise.lock` entries are not filtered by mise;
npm/pnpm/uv apply their gate to the install itself, so an exact version younger
than the window needs a one-command override.

Prefer a one-command override over a persistent exclude. A persistent list
weakens the gate for every future version of that package; a one-shot command
is scoped to the change that needs it.

## Exception log

All dates UTC. "Gate opens" is the first day the version passes the 14-day
window.

| Date | Component | Exception | Reason | Gate opens | Status |
| --- | --- | --- | --- | --- | --- |
| 2026-11-05 | uv `0.12` -> `0.13.5` | none; minor pin bump | GHSA-hq85-5cpj-mr62 / PYSEC-2026-4321: the vendored CA store trusted a compromised eMudhra/emSign root. Fixed in 0.13.4. | already eligible | host installed; repo pin follow-up below |
| 2026-11-05 | Python `3.14.9` -> `3.14.10` | `mise upgrade --minimum-release-age 0s python` | CVE-2026-115557 (compromised-cert denylist; NVD 9.4) and CVE-2026-114583 (`tarfile.tar_filter` traversal; NVD 6.9). | 2026-11-08 | installed; exception ages out |
| 2026-11-05 | Terraform `1.16.6` -> `1.16.7` | none; eligible | Built with Go 1.26.10, which includes GO-2026-6809 / CVE-2026-111943 (eMudhra CA denylist). | already eligible | installed |
| 2026-11-05 | kubectl `1.37.1` -> `1.37.2` | `mise upgrade --minimum-release-age 0s kubectl` | Rebuilt with Go 1.26.10 for GO-2026-6809; the gate would have delayed it. | 2026-11-11 | installed via one-shot |
| 2026-11-05 | Flux `2.8.7` / `2.9.6` -> `2.10.0` | `mise upgrade --minimum-release-age 0s flux2` | Rebuilt with Go 1.27.3 for GO-2026-6809. Host pin also corrected from exact `2.8.7` to `2`. | 2026-11-09 | installed via one-shot |
| 2026-11-05 | Pi `1.1.0` -> `1.5.0` | exact pin, plus `npm_config_min_release_age=0` for the install | 1.1.0 bundled `undici 8.10.2` (8 advisories, including the TLS certificate-validation bypass GHSA-2m5v-pch6-74hx) and `minimatch 10.2.6` (ReDoS GHSA-g3hv-75wg-m249). 1.5.0 pins `undici 8.12.3` and `minimatch 11.0.3`. | 2026-11-16 | installed; review by 2026-11-16 |
| 2026-11-05 | Node `24.22.1` | none | Already the 2026-10-21 security release, including the eMudhra ca-cert update. The next security release is 2026-11-11. | next release 2026-11-25 | monitoring |

Notes:

- The Python and kubectl/Flux one-shot installs are not downgraded by later
  `mise upgrade` runs; the exception expires when the version ages past the
  window.
- The Pi bump is an exact-pin exception, not a gate override: exact pins bypass
  `minimum_release_age` by design. The npm gate was separately overridden for
  the install because 1.5.0 was three days old.
- Pi 1.5.0's installed dependency tree was scanned with OSV: 0 hits across 126
  packages. A fresh Pi session is required to pick it up.

## Repo pin state

This record describes the host after the 2026-11-05 response. Pin changes land
separately; verify `template/setup-mise.sh` before the next bootstrap. In
particular:

- The host `uv` is 0.13.5, but the script still pins `uv@0.12`. Bump it before
  the next bootstrap so the vulnerable minor cannot be reintroduced.
- The Pi `1.5.0` bump is in `template/setup-mise.sh` and must be committed with
  (or before) the next toolchain change.

## Accepted or deferred risk

These are known and not blocked on a decision. Review them at the next monthly
security pass.

- **Go tools without a fixed release.** `helm 4.3.1` (Go 1.27.2), `k9s 0.51.0`
  (Go 1.26.1), `sops 3.13.3` (Go 1.26.5), `lazygit 0.66.2` (Go 1.26.9),
  `fzf 0.74.5` (Go 1.27.2), and `flate 0.6.5` (Go 1.27.0) are built below the
  GO-2026-6809 fix threshold (1.26.10 / 1.27.3). No newer release exists yet.
  Mitigation: neither the Fedora 44 bundle nor the Ubuntu 24.04 devcontainer
  base image trusts `emSign ECC Root CA - G3`, the root named in the uv
  advisory, so the specific chain is not trusted here. Keep
  `ca-certificates` current and upgrade each tool when upstream rebuilds.
- **Go transitive dependencies.** The same binaries bundle older `x/net`,
  `x/crypto`, `go-jose`, and (in Flux 2.8.x) Helm/go-git/containerd modules
  with module-level OSV hits. Reachability is not established. Flux 2.10.0,
  kubectl 1.37.2, and Terraform 1.16.7 cut the exposure substantially; the
  remaining hits are upstream build choices, not local pins.
- **Exact pins do not move.** Pi, `pi-venice`, `sops`, and `flate` are exact;
  Mason's `name@version` entries are exact by necessity. They will not pick up
  a patch automatically. Review them monthly; the Pi review date is above.
- **Host config drift.** `sops` is exact `3.13.3` on the host while the script
  says `3.13`; `flate` is installed but absent from
  `~/.config/mise/config.toml`. Reconcile on the next bootstrap. Neither is a
  current CVE blocker.
- **Supply-chain backlog.** DevPod is installed from `releases/latest` without
  a checksum; mise is bootstrapped via `curl | sh`; the devcontainer base
  image is a tag and both features use `"version": "latest"`; skill packs are
  cloned at movable tags. These are tracked as separate follow-ups, not part
  of this incident.

## Verification

Checked on 2026-11-05 in a freshly activated shell:

```text
mise settings get minimum_release_age   -> 14d
mise settings get locked_scopes         -> ["project"]
uv --version                            -> 0.13.5
python3 -VV                             -> 3.14.10
terraform version                       -> 1.16.7 (go1.26.10)
kubectl version --client                -> v1.37.2
flux --version                          -> 2.10.0
pi --version                            -> 1.5.0
node --version                          -> v24.22.1
go version                              -> go1.27.3
```

## Adding an exception

1. Prefer a one-shot override: `mise upgrade --minimum-release-age 0s <tool>`,
   `npm install --min-release-age=0`,
   `pnpm install --config.minimumReleaseAge=0`, or
   `uv ... --exclude-newer false`.
2. Add a row to the exception log before or with the change: component,
   from/to version, advisory, reason, gate date, review date.
3. Use a persistent exclusion (`minimum_release_age_excludes`,
   `min-release-age-exclude`, `minimumReleaseAgeExclude`,
   `exclude-newer-package`) only when the same package repeatedly needs to
   lead the gate. Record why, and revisit it.
4. For exact pins, record the review date; the gate cannot protect them.

## References

- uv: <https://github.com/advisories/GHSA-hq85-5cpj-mr62>
- Go: GO-2026-6809 / CVE-2026-111943, <https://go.dev/issue/82345>
- Python: CVE-2026-115557, CVE-2026-114583
- Pi: GHSA-2m5v-pch6-74hx, GHSA-g3hv-75wg-m249
- Node.js October 2026 security release:
  <https://nodejs.org/en/blog/vulnerability/october-2026-security-releases>
