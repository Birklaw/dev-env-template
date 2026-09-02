#!/bin/bash
# Debian-family host bootstrap: Debian proper and Armbian/Debian images
# (tested: Orange Pi 5B, aarch64, Armbian Debian trixie). System packages +
# docker-ce + devpod + VS Code, then the shared mise toolchain. Run via
# ../bootstrap.sh (or directly on a host being validated for the router
# allowlist). Distro-agnostic steps live in ../lib/common.sh.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_sudo_user
command -v apt-get &>/dev/null || { echo "ERROR: not an apt-based host" >&2; exit 1; }

APT="sudo DEBIAN_FRONTEND=noninteractive apt-get"

# ---------- host identity: apt-suite resolution (fail-closed) ----------
# The third-party apt repos below (docker, microsoft, github) publish
# suites for a fixed set of releases; anything else fails with cryptic 404s
# mid-install, so unknown $DISTRO/$CODENAME pairs stop here instead.
# The allowlist left-hand side is load-bearing: $DISTRO feeds
# download.docker.com/linux/$DISTRO, so it must be the BASE distro
# (debian|ubuntu), not the vendor.
#
# /etc/armbian-release is the Armbian marker, but its distro fields vary
# by image generation — observed on Armbian trixie:
# DISTRIBUTION / DISTRIBUTION_CODENAME are NOT defined there. Armbian
# fields win when present, else /etc/os-release ID/VERSION_CODENAME, then
# the allowlist validates whatever comes out.
if [ -f /etc/armbian-release ]; then
  # shellcheck disable=SC1091
  . /etc/armbian-release          # marker present; distro fields optional
fi
# shellcheck disable=SC1091
. /etc/os-release                 # ID, VERSION_CODENAME
DISTRO="${DISTRIBUTION:-${ID:-}}"
CODENAME="${DISTRIBUTION_CODENAME:-${VERSION_CODENAME:-}}"
DISTRO="${DISTRO,,}"
CODENAME="${CODENAME,,}"
if [ -z "$DISTRO" ] || [ -z "$CODENAME" ]; then
  echo "ERROR: could not resolve distro/codename" >&2
  echo "  armbian-release: DISTRIBUTION='${DISTRIBUTION:-}' DISTRIBUTION_CODENAME='${DISTRIBUTION_CODENAME:-}'" >&2
  echo "  os-release: ID='${ID:-}' VERSION_CODENAME='${VERSION_CODENAME:-}'" >&2
  echo "  cat /etc/os-release /etc/armbian-release, pin the observed fields" >&2
  echo "  into the resolution above and the allowlist below." >&2
  exit 1
fi
case "$DISTRO/$CODENAME" in
  debian/trixie) ;; # tested: Armbian trixie on Orange Pi 5B
  *)
    echo "ERROR: unsupported release: $DISTRO/$CODENAME" >&2
    echo "  If the docker/microsoft/github apt repos publish a suite for it," >&2
    echo "  add it to the allowlist above and retest; otherwise stop here." >&2
    echo "  (Cat of /etc/os-release /etc/armbian-release needed to proceed.)" >&2
    exit 1
    ;;
esac

# ---------- system packages (base) ----------
# Mirrors the fedora target's list. build-essential = gcc/make (also the
# compiler tree-sitter needs for nvim parsers); fontconfig serves fc-cache
# and xz-utils the tar -xJf in the nerd-font step, both absent on minimal
# Armbian/Debian images.
sudo apt-get update
$APT install -y ca-certificates curl fontconfig xz-utils git vim build-essential tmux

# ---------- system libs for native Node.js / pnpm binaries ----------
# Minimal ARM images can lack libatomic, causing "libatomic.so.1: cannot
# open shared object file" errors for node/pnpm — mirrors the container path.
if ! ldconfig -p 2>/dev/null | grep -q libatomic.so.1; then
  echo "==> Installing libatomic1..."
  $APT install -y libatomic1
fi

# ---------- apt keyrings for the third-party repos below ----------
sudo install -m 0755 -d /etc/apt/keyrings

# ---------- gh (GitHub CLI): upstream apt repo ----------
# Trixie ships gh 2.46 (stale, predates upstream API changes); GitHub's
# repo publishes current arm64 builds.
if [ ! -f /etc/apt/sources.list.d/github-cli.list ]; then
  echo "==> Adding GitHub CLI apt repo..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
fi

# ---------- docker-ce: official Docker apt repo (deb822) ----------
# Not docker.io: the Debian package lags upstream and splits the plugin
# package names. deb822 (.sources) is Trixie's default format; the key
# stays ASCII-armored (.asc) — apt >= 2.4 accepts that, so no gpg
# dependency.
if [ ! -f /etc/apt/sources.list.d/docker.sources ]; then
  echo "==> Adding Docker apt repo ($DISTRO/$CODENAME)..."
  sudo curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DISTRO
Suites: $CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi

# ---------- VS Code (one global install on the host; NOT per container) --
# Microsoft's apt repo publishes amd64/arm64/armhf debs, so aarch64 boards
# install identically to the x86 path. Same armored-key + deb822 pattern.
if [ ! -f /etc/apt/sources.list.d/vscode.sources ]; then
  echo "==> Adding VS Code apt repo..."
  sudo curl -fsSL "https://packages.microsoft.com/keys/microsoft.asc" \
    -o /etc/apt/keyrings/microsoft.asc
  sudo chmod a+r /etc/apt/keyrings/microsoft.asc
  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/microsoft.asc
EOF
fi

# ---------- install from first-party + third-party repos ----------
sudo apt-get update
$APT install -y gh code
if ! command -v docker &>/dev/null; then
  echo "==> Installing docker-ce..."
  $APT install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi
enable_docker

# ---------- devpod CLI + dotfiles defaults ----------
install_devpod
configure_devpod
install_vscode_extensions

# ---------- Nerd Font symbols ----------
install_nerd_font

# ---------- mise + shared toolset ----------
run_toolchain_install

echo "==> Debian-family host bootstrap complete ($DISTRO/$CODENAME)."
echo "    Reboot (or log out/in) so docker group membership applies, then:"
echo "      devpod up <path-or-git-url> --ide vscode"
