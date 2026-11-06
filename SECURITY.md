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

## Supply-chain controls

Added on 2026-11-05/06:

- **DevPod CLI**: pinned to `v0.6.15`. Every bootstrap hashes the installed
  `/usr/local/bin/devpod` against the per-arch SHA-256 hardcoded in
  `lib/common.sh` and replaces it on mismatch, so hosts bootstrapped before the
  pin are verified too; a devpod installed elsewhere is left alone with a
  warning. The stable pin deliberately wins over a newer or alpha build at that
  path. Upstream publishes no CLI checksum file or attestation. armv7 fails
  closed, as no asset is published.
- **mise**: bootstrapped from a pinned release; the `.tar.gz` archive is
  verified against a SHA-256 hardcoded in `template/setup-mise.sh`, with the
  official installer as the fallback for an unknown arch or a failed download.
  The archive hash covers first install; after that the self-updated binary
  tracks the release channel, held to releases older than 14 days via
  `self_update.minimum_release_age` (`self_update.auto = true`). The fallback
  verifies against the release's own `SHASUMS256.txt` (same origin as the
  archive), so it detects transport corruption, not a swapped release.
- **Dependabot / GitHub Actions**: `.github/dependabot.yml` covers the
  devcontainer definition and GitHub Actions. The workflow action
  (`actions/checkout`) is pinned by commit SHA with a version comment, and the
  Dependabot `github-actions` ecosystem updates it.
- **Devcontainer features**: refs pinned to exact tags and tool versions
  (`docker-outside-of-docker:1.10.1` -> moby 29.9.2, buildx 0.38.1, compose
  v2; `github-cli:1.1.3` -> gh 2.97.0). The base image stays `ubuntu-24.04`.
- **Skill packs**: pinned to commit SHAs; `--ref` rejects a non-SHA value.
- **ca-certificates**: upgraded explicitly on host bootstrap and container
  post-create (GO-2026-6809 mitigation for tools built below Go 1.26.10).
- **Toolchain pins**: uv moved to 0.13 and Pi to 1.5.0 in
  `template/setup-mise.sh`, committing the exception-log entries above.

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
  `ca-certificates` current and upgrade each tool when upstream rebuilds. The
  gated build-version hits are listed in the scan baseline below.
- **Go transitive dependencies.** The same binaries bundle older `x/net`,
  `x/crypto`, `go-jose`, and (in Flux 2.8.x) Helm/go-git/containerd modules
  with module-level OSV hits. Reachability is not established. Flux 2.10.0,
  kubectl 1.37.2, and Terraform 1.16.7 cut the exposure substantially; the
  remaining hits are upstream build choices, not local pins.
- **Mason-installed tools.** The scan reads the installed Mason packages and
  reports advisories in their dependency trees and Go build versions; these
  are **report-only**, not part of the gate, because Mason is host-local. As of
  2026-11-06: `undici 6.26.0` in a Mason tree carries
  GHSA-2m5v-pch6-74hx, the same TLS-validation-bypass advisory that motivated
  the Pi 1.5.0 bump; plus transitive npm hits (`brace-expansion`, `fast-uri`,
  `glob`, `ip-address`, `katex`, `markdown-it`, `minimatch`,
  `postcss-selector-parser`, `smol-toml`, `tar`, `toml`, `zod`) and Go stdlib
  build versions below the fix threshold in `helm-ls`, `terraform-ls`,
  `tflint`, `shfmt`, and `golangci-lint`. Reachability is not established; the
  fix path is `:MasonUpdate` or a reinstall of the affected tool. Review at the
  next monthly pass. `ruff`, `stylua`, `taplo`, `hadolint`, `shellcheck`,
  `lua-language-server`, `marksman`, and `js-debug-adapter` ship no
  machine-readable manifest and stay manual.
- **Exact pins do not move.** `pi` and `pi-venice` are exact, and Pi is the hot
  target; review monthly (Pi review date above). `sops` and `flate` float at
  their minor boundary again, so the 14-day gate covers their patches.
- **Host config.** Reconciled on 2026-11-06: `sops = "3.13"`,
  `github:home-operations/flate = "0.6"`, and the self-update settings are in
  `~/.config/mise/config.toml`. Keep it matching `template/setup-mise.sh`.
- **Open item.** The devcontainer base image is still a tag (`ubuntu-24.04`);
  a digest pin is not in place. The features and their tool versions are
  pinned, the mise installer is pinned and verified, and the workflow runs the
  scan on the declared pins.

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
devpod version                          -> v0.6.15
node --version                          -> v24.22.1
go version                              -> go1.27.3
```

## Scan baseline

`scripts/security-scan.py` reads the block below. A finding listed here is
expected and does not fail the gate; a finding not listed does. Keys are
precise — `<section>|<identity>|<advisory-id>` — so a new advisory on the same
build, or the same advisory on a new build, is a new key. Stale keys (listed
but no longer reported) are printed without failing, so a pin bump flags the
line to remove. Mason findings — npm/pip transitive versions and Mason-only Go
build versions — are report-only and are not listed. Regenerate the current
keys with `scripts/security-scan.py --print-keys`.

<!-- security-scan-accepted
stdlib|go1.26.1|GO-2026-4864
stdlib|go1.26.1|GO-2026-4865
stdlib|go1.26.1|GO-2026-4866
stdlib|go1.26.1|GO-2026-4869
stdlib|go1.26.1|GO-2026-4870
stdlib|go1.26.1|GO-2026-4918
stdlib|go1.26.1|GO-2026-4946
stdlib|go1.26.1|GO-2026-4947
stdlib|go1.26.1|GO-2026-4971
stdlib|go1.26.1|GO-2026-4976
stdlib|go1.26.1|GO-2026-4977
stdlib|go1.26.1|GO-2026-4980
stdlib|go1.26.1|GO-2026-4981
stdlib|go1.26.1|GO-2026-4982
stdlib|go1.26.1|GO-2026-4986
stdlib|go1.26.1|GO-2026-5037
stdlib|go1.26.1|GO-2026-5038
stdlib|go1.26.1|GO-2026-5039
stdlib|go1.26.1|GO-2026-6603
stdlib|go1.26.1|GO-2026-6610
stdlib|go1.26.1|GO-2026-6611
stdlib|go1.26.1|GO-2026-6612
stdlib|go1.26.1|GO-2026-6617
stdlib|go1.26.5|GO-2026-6603
stdlib|go1.26.5|GO-2026-6610
stdlib|go1.26.5|GO-2026-6611
stdlib|go1.26.5|GO-2026-6612
stdlib|go1.26.5|GO-2026-6617
stdlib|go1.27.0|GO-2026-6599
stdlib|go1.27.0|GO-2026-6600
stdlib|go1.27.0|GO-2026-6603
stdlib|go1.27.0|GO-2026-6604
stdlib|go1.27.0|GO-2026-6605
stdlib|go1.27.0|GO-2026-6607
stdlib|go1.27.0|GO-2026-6608
stdlib|go1.27.0|GO-2026-6609
stdlib|go1.27.0|GO-2026-6610
stdlib|go1.27.0|GO-2026-6611
stdlib|go1.27.0|GO-2026-6612
stdlib|go1.27.0|GO-2026-6613
stdlib|go1.27.0|GO-2026-6617
stdlib|go1.27.0|GO-2026-6809
stdlib|go1.27.2|GO-2026-6809
-->

## Recurring checks

Two-weekly, aligned with the 14-day gate:

```bash
scripts/security-scan.py                     # gate: fails only on a new (non-baseline) finding
scripts/security-scan.py --deep --warn-only  # deep triage report, never fails
scripts/security-scan.py --no-accepted       # strict: every finding fails
scripts/security-scan.py --print-keys        # regenerate the baseline block
```

The scan resolves the mise pins to the installed versions, queries OSV for
npm, PyPI, crates.io and Go modules, and checks each Go tool's stdlib build
version against the Go vuln DB. It also reads the installed Mason packages
(npm and pip manifests, plus each Go binary's build info). It prints manual
upstream links for the pins OSV cannot cover (node, python, neovim, herdr,
devcontainer features, skill packs, the base image, and Mason tools without a
manifest). A failed Go vuln index fetch or a missing `stdlib` entry fails the
run (exit 2) rather than reporting green; advisories the index cannot place on
the build's branch are printed as `UNEVALUATED` and are report-only.

`.github/workflows/security-scan.yml` runs the scan on the 1st and 15th; it
fails only on a finding that is not in the baseline below, so the accepted
upstream build versions keep the job green while a genuinely new hit fails it.
It installs the pinned toolchain so floating pins resolve to real versions.
Mason coverage is not available there (Mason is a host-side nvim install) and
is report-only locally too, so the local run stays the complete one.
`.github/workflows/tests.yml` runs `tests/run.sh` on every push and pull
request, so the SHA-ref guard, the atomic skill checkout, and the scan's
fail-closed stdlib behaviour are enforced before merge. The scan itself only
runs on its schedule. `.github/dependabot.yml` opens version-update PRs for the
devcontainer definition and GitHub Actions; both workflows pin
`actions/checkout` by commit SHA and Dependabot keeps it current. Dependabot
follows upstream tags, the scan follows advisories.

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
