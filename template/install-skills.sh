#!/bin/bash
# Skill-pack installer — shared by the host bootstrap (lib/common.sh
# run_toolchain_install) and every devcontainer (.devcontainer/post-create.sh).
#
# Pi discovers skills from the Agent Skills global location (~/.agents/skills).
# This script installs one or more *skill packs* there: it clones each pack at
# a fixed ref and symlinks its skill folders into place. Skill folders are
# discovered recursively, so a pack may lay them out flat or grouped in
# subdirectories. Because a pack may reference files shared across its skills
# by relative path, the full checkout is kept and any shared directories are
# exposed alongside the skills — it never copies just the skill folders.
#
# ADDING A PACK: add an install_pack call at the bottom of this file. Options:
#
#   --repo <url>        git URL (required)
#   --ref <ref>         tag/branch/commit the pack is held at (required)
#   --subdir <dir>      directory inside the repo that holds the skills
#                       (default: skills)
#   --include <a,b,..>  install only these skill names (optional; default: all)
#   --omit <a,b,..>     never install these skill names (optional)
#   --shared <a,b,..>   repo-root directories to expose at ~/.agents/<dir>, so
#                       a skill's ../../<dir> links resolve (optional)
#
# Skills are symlinked individually, so --include/--omit select a subset of a
# pack. Later packs win if two define the same skill name; keep names disjoint
# or omit the duplicate.
set -euo pipefail

SKILLS_HOME="${SKILLS_HOME:-$HOME/.agents}"
SKILLS_DEST="$SKILLS_HOME/skills"
CHECKOUT_ROOT="${CHECKOUT_ROOT:-$HOME/.local/share/agent-skills}"

log() { echo "==> $*"; }

checkout_dir() { echo "$CHECKOUT_ROOT/$1"; }

csv_contains() {
  local csv="$1" needle="$2" item
  [ -z "$csv" ] && return 1
  local -a items=()
  IFS=',' read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

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
  local name="$1"; shift
  local repo="" ref="" subdir="skills" include="" omit="" shared=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --ref) ref="$2"; shift 2 ;;
      --subdir) subdir="$2"; shift 2 ;;
      --include) include="$2"; shift 2 ;;
      --omit) omit="$2"; shift 2 ;;
      --shared) shared="$2"; shift 2 ;;
      *) echo "ERROR: install_pack $name: unknown option '$1'" >&2; exit 1 ;;
    esac
  done
  if [ -z "$repo" ] || [ -z "$ref" ]; then
    echo "ERROR: install_pack $name requires --repo and --ref" >&2
    exit 1
  fi

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

  local linked=0 skill_md skill_dir skill_name
  while IFS= read -r skill_md; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    if [ -n "$include" ] && ! csv_contains "$include" "$skill_name"; then
      continue
    fi
    if csv_contains "$omit" "$skill_name"; then
      log "Skipping $name/$skill_name (omitted)."
      continue
    fi
    ln -sfn "$skill_dir" "$SKILLS_DEST/$skill_name"
    linked=$((linked + 1))
  done < <(find "$skills_src" -name SKILL.md -not -path '*/node_modules/*' | sort)

  # Expose shared pack directories so ../../<dir> resolves from each symlinked
  # skill directory.
  local s
  local -a shared_items=()
  [ -n "$shared" ] && IFS=',' read -ra shared_items <<< "$shared"
  for s in "${shared_items[@]}"; do
    [ -n "$s" ] && [ -e "$dir/$s" ] && ln -sfn "$dir/$s" "$SKILLS_HOME/$s"
  done

  log "Skill pack '$name': $linked skills linked (ref $ref)."
}

mkdir -p "$SKILLS_DEST"

# --- packs -----------------------------------------------------------------
# Add new packs here. See the header for the option reference.

install_pack osmani \
  --repo https://github.com/addyosmani/agent-skills.git \
  --ref 0.6.12 \
  --omit using-agent-skills \
  --shared references

install_pack pocock \
  --repo https://github.com/mattpocock/skills.git \
  --ref v1.3.1 \
  --include grill-me,grill-with-docs,wayfinder,prototype,research,improve-codebase-architecture,writing-for-agents,pr,codebase-design,domain-modeling,grilling,setup-matt-pocock-skills

log "Skill packs installed in $SKILLS_DEST."
