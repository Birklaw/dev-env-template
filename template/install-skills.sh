#!/bin/bash
# Skill-pack installer — shared by the host bootstrap (lib/common.sh
# run_toolchain_install) and every devcontainer (.devcontainer/post-create.sh).
#
# Pi discovers skills from the Agent Skills global location (~/.agents/skills).
# This script installs one or more *skill packs* there: it clones each pack at
# a fixed ref and symlinks the pack's skill folders into place. Because a pack
# may reference files shared across its skills by relative path, the full
# checkout is kept and those shared directories are exposed alongside the
# skills — it never copies just the skill folders.
#
# ADDING A PACK: add one line to SKILL_PACKS below. Format:
#
#   name|repo|ref|subdir|omit_csv|shared_csv
#
#   name        label for logs and for this pack's checkout directory
#   repo        git URL
#   ref         tag/branch/commit the pack is held at (reproducible across
#               the host and every devpod; bump deliberately)
#   subdir      directory inside the repo that holds the skill folders
#               (default: skills)
#   omit_csv    comma-separated skill folder names to leave out (optional)
#   shared_csv  comma-separated repo-root directories to expose at
#               ~/.agents/<dir>, so a skill's ../../<dir> links resolve
#               (optional)
#
# Later packs win if two define the same skill name; keep names disjoint or
# omit the duplicate.
set -euo pipefail

SKILLS_HOME="${SKILLS_HOME:-$HOME/.agents}"
SKILLS_DEST="$SKILLS_HOME/skills"
CHECKOUT_ROOT="${CHECKOUT_ROOT:-$HOME/.local/share/agent-skills}"

SKILL_PACKS=(
  "osmani|https://github.com/addyosmani/agent-skills.git|0.6.12|skills|using-agent-skills|references"
)

log() { echo "==> $*"; }

checkout_dir() { echo "$CHECKOUT_ROOT/$1"; }

# Clone a pack at its ref, or re-pin an existing checkout when the ref moved.
ensure_checkout() {
  local name="$1" repo="$2" ref="$3" dir
  dir="$(checkout_dir "$name")"
  if [ ! -d "$dir/.git" ]; then
    log "Cloning skill pack '$name' at $ref..."
    mkdir -p "$CHECKOUT_ROOT"
    git clone --depth 1 --branch "$ref" "$repo" "$dir"
  elif [ "$(git -C "$dir" describe --tags --exact-match 2>/dev/null || true)" != "$ref" ]; then
    log "Re-pinning skill pack '$name' to $ref..."
    rm -rf "$dir"
    git clone --depth 1 --branch "$ref" "$repo" "$dir"
  else
    log "Skill pack '$name' already at $ref."
  fi
}

install_pack() {
  local name="$1" repo="$2" ref="$3" subdir="$4" omit_csv="$5" shared_csv="$6"
  local dir skills_src
  ensure_checkout "$name" "$repo" "$ref"
  dir="$(checkout_dir "$name")"
  skills_src="$dir/$subdir"

  if [ ! -d "$skills_src" ]; then
    echo "WARNING: skill pack '$name' has no '$subdir' directory; skipping." >&2
    return 0
  fi

  # Drop symlinks we previously made into this pack, so removed, renamed, or
  # newly-omitted skills do not linger.
  find "$SKILLS_DEST" -maxdepth 1 -type l -lname "$dir/*" -delete

  local -a omit=() shared=()
  [ -n "$omit_csv" ] && IFS=',' read -ra omit <<< "$omit_csv"
  [ -n "$shared_csv" ] && IFS=',' read -ra shared <<< "$shared_csv"

  local linked=0 skill_dir skill_name skip o
  for skill_dir in "$skills_src"/*/; do
    [ -f "${skill_dir}SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    skip=0
    for o in "${omit[@]}"; do
      [ "$skill_name" = "$o" ] && skip=1
    done
    if [ "$skip" = 1 ]; then
      log "Skipping $name/$skill_name (omitted)."
      continue
    fi
    ln -sfn "${skill_dir%/}" "$SKILLS_DEST/$skill_name"
    linked=$((linked + 1))
  done

  # Expose shared pack directories so ../../<dir> resolves from each symlinked
  # skill directory.
  local s
  for s in "${shared[@]}"; do
    [ -e "$dir/$s" ] && ln -sfn "$dir/$s" "$SKILLS_HOME/$s"
  done

  log "Skill pack '$name': $linked skills linked (ref $ref)."
}

mkdir -p "$SKILLS_DEST"

for spec in "${SKILL_PACKS[@]}"; do
  IFS='|' read -r p_name p_repo p_ref p_subdir p_omit p_shared <<< "$spec"
  install_pack "$p_name" "$p_repo" "$p_ref" "${p_subdir:-skills}" "$p_omit" "$p_shared"
done

log "Skill packs installed in $SKILLS_DEST."
