# dev-env-template — agent notes

A pointer, not a duplicate: `README.md` has the full picture, `SECURITY.md`
has the supply-chain policy, the scan baseline, and the accepted risk.

- Run `scripts/check.sh` for everything (bash -n, shellcheck, Python syntax,
  `tests/run.sh`, whitespace). CI runs the same script.
- Layout: `bootstrap.sh` routes by OS into `targets/*`; shared host steps live
  in `lib/common.sh`; the toolchain is `template/setup-mise.sh`; agent setup is
  `template/install-skills.sh` and `template/install-pi-packages.sh`; the
  container is `template/.devcontainer/`; the scan is
  `scripts/security-scan.py`.
- Tests: `tests/run.sh`; privileged commands are stubbed by `tests/fakes/`.
- Reviews land in `tmp/reviews/` (`tmp/` is gitignored).
- Commits: one per verified slice on a short-lived branch; the branch is
  reviewed before it lands. Cross-cutting rules live in `~/.pi/agent/AGENTS.md`.
