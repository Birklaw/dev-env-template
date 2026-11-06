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
#   --ref <sha>         full 40-char commit SHA the pack is held at (required);
#                       tags are movable, so record the release tag in a
#                       comment beside the call instead
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

# Clone a pack at its commit, or re-pin an existing checkout when the commit
# differs. Commits are fetched explicitly: `git clone --branch` accepts a
# branch or tag, not a raw SHA.
ensure_checkout() {
  local name="$1" repo="$2" ref="$3" dir current="" tmp backup=""
  dir="$(checkout_dir "$name")"
  if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "ERROR: ensure_checkout $name: ref must be a full 40-character commit SHA (got '$ref')" >&2
    exit 1
  fi
  if [ -d "$dir/.git" ]; then
    current="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [ "$current" = "$ref" ]; then
    log "Skill pack '$name' already at $ref."
    return 0
  fi
  log "Cloning skill pack '$name' at $ref..."
  # Fetch into a temp dir and swap only after a successful checkout, so a
  # failed re-pin leaves the previous checkout in place instead of an empty
  # directory that fails the whole bootstrap.
  mkdir -p "$CHECKOUT_ROOT"
  # Sweep temp checkouts left by an interrupted run.
  # Only temp dirs from an interrupted run: leave a concurrent run's fresh one alone.
  find "$CHECKOUT_ROOT" -maxdepth 1 -name '.checkout.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  tmp="$(mktemp -d "$CHECKOUT_ROOT/.checkout.XXXXXX")"
  if ! git -C "$tmp" init -q; then
    rm -rf "$tmp"
    echo "ERROR: could not initialise a checkout for $repo" >&2
    exit 1
  fi
  git -C "$tmp" remote add origin "$repo"
  if ! git -C "$tmp" fetch --depth 1 origin "$ref"; then
    rm -rf "$tmp"
    echo "ERROR: could not fetch $repo at $ref (previous checkout left in place)" >&2
    exit 1
  fi
  if ! git -C "$tmp" checkout -q --detach FETCH_HEAD; then
    rm -rf "$tmp"
    echo "ERROR: could not check out $ref in $repo" >&2
    exit 1
  fi
  if [ -e "$dir" ]; then
    backup="${dir}.old"
    rm -rf "$backup"
    if ! mv "$dir" "$backup"; then
      rm -rf "$tmp"
      echo "ERROR: could not move the previous checkout aside" >&2
      exit 1
    fi
  fi
  if ! mv "$tmp" "$dir"; then
    if [ -n "$backup" ]; then mv "$backup" "$dir"; fi
    rm -rf "$tmp"
    echo "ERROR: could not move the new checkout into $dir" >&2
    exit 1
  fi
  if [ -n "$backup" ]; then
    rm -rf "$backup"
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
  if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "ERROR: install_pack $name: --ref must be a full 40-character commit SHA (got '$ref')" >&2
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

main() {
  mkdir -p "$SKILLS_DEST"

  # --- packs -----------------------------------------------------------------
  # Add new packs here. See the header for the option reference.

  # addyosmani/agent-skills 0.6.12
  install_pack osmani \
    --repo https://github.com/addyosmani/agent-skills.git \
    --ref a06bc63b3f8b829c14b0bbf53d99fefc39d58092 \
    --omit using-agent-skills \
    --shared references

  # mattpocock/skills v1.3.1
  install_pack pocock \
    --repo https://github.com/mattpocock/skills.git \
    --ref 24fe0ef7737efae15c87225755e9f6f5965e4888 \
    --include grill-me,grill-with-docs,wayfinder,prototype,research,improve-codebase-architecture,writing-for-agents,pr,codebase-design,domain-modeling,grilling,setup-matt-pocock-skills

  log "Skill packs installed in $SKILLS_DEST."
}

# The functions above are sourceable for tests; install the packs only when
# the script is executed directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
