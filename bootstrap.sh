#!/bin/bash
# Host bootstrap router: detect the OS, dispatch to a family target.
#
# Fail-closed by design. The case below IS the support matrix: a host is
# supported because a target has been run on it — never because os-release
# metadata claims compatibility. ID_LIKE is never used to route; on failure
# it is printed as a hint only. To add a host: run the matching target in
# targets/ directly, verify, then add the detected $ID to the case.
#
# /etc/armbian-release is the one non-ID input: a deterministic vendor
# marker (Armbian varies in what it leaves in /etc/os-release) that routes
# Armbian into the debian family. Its release still has to pass the
# codename allowlist inside targets/debian.sh.
#
# Router dry runs (no system changes):
#   ./bootstrap.sh --print-family
#   BOOTSTRAP_OS_RELEASE=/path/to/mock BOOTSTRAP_ARMBIAN_RELEASE=/path/to/mock \
#     ./bootstrap.sh --print-family
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OS_RELEASE="${BOOTSTRAP_OS_RELEASE:-/etc/os-release}"
ARMBIAN_RELEASE="${BOOTSTRAP_ARMBIAN_RELEASE:-/etc/armbian-release}"

[ -r "$OS_RELEASE" ] || { echo "ERROR: no readable $OS_RELEASE — unsupported host" >&2; exit 1; }
# shellcheck disable=SC1090
. "$OS_RELEASE"                 # ID, PRETTY_NAME, VERSION_CODENAME; ID_LIKE = hint only

family=""
if [ -f "$ARMBIAN_RELEASE" ]; then
  # shellcheck disable=SC1090
  . "$ARMBIAN_RELEASE"         # DISTRIBUTION, DISTRIBUTION_CODENAME
  family=debian
else
  case "${ID:-}" in
    fedora) family=fedora ;;
    debian) family=debian ;;
    *)
      echo "ERROR: unsupported OS: ${PRETTY_NAME:-unknown}" >&2
      echo "  detected: ID='${ID:-}' ID_LIKE='${ID_LIKE:-}' codename='${VERSION_CODENAME:-}'" >&2
      echo "  ID_LIKE (if set) hints which target fits; test targets/fedora.sh or" >&2
      echo "  targets/debian.sh directly on this host, then add '${ID:-<id>}' to the" >&2
      echo "  case in bootstrap.sh." >&2
      exit 1
      ;;
  esac
fi

if [ "${1:-}" = "--print-family" ]; then
  echo "$family"
  exit 0
fi

if [ -n "${DISTRIBUTION:-}" ]; then
  echo "==> Armbian: $DISTRIBUTION/$DISTRIBUTION_CODENAME"
fi

exec bash "$ROOT/targets/$family.sh"
