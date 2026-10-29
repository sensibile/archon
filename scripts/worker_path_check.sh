#!/usr/bin/env bash
# Checks that a Taeguk worker PR only changes paths its worker may change
# before auto-merge is enabled. See docs/operations.md.
#
# Usage: scripts/worker_path_check.sh <test-gap|daily-cleanup> [base] [head]
#   base defaults to origin/main, head defaults to HEAD.
#
# Exit codes: 0 every changed path is allowed, 1 out-of-scope paths found
# (printed to stdout), 2 usage or git error. Only exit 0 passes.

set -u
# Byte-wise globs and tr: non-ASCII paths are rejected below, not case-folded.
export LC_ALL=C

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <test-gap|daily-cleanup> [base] [head]" >&2
  exit 2
fi

worker="${1:-}"
base="${2:-origin/main}"
head="${3:-HEAD}"

case "$worker" in
  test-gap | daily-cleanup) ;;
  *)
    echo "usage: $0 <test-gap|daily-cleanup> [base] [head]" >&2
    exit 2
    ;;
esac

allowed_path() {
  # Only printable ASCII: APFS folds some non-ASCII letters (U+017F to s), so
  # docs/operation\u017f.md would overwrite docs/operations.md on checkout.
  case "$1" in
    *[!\ -~]*) return 1 ;;
  esac

  # Protected records are matched case-insensitively: on a case-insensitive
  # checkout docs/ADR/x.md lands next to the real ADRs.
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    docs/adr/* | docs/operations.md) return 1 ;;
    # A PR-controlled .gitattributes can hide diffs from review or binaries from this check.
    .gitattributes | */.gitattributes | .gitignore | */.gitignore | .gitmodules | */.gitmodules) return 1 ;;
    # Agent instructions found in subdirectories would steer later sessions.
    agents*.md | */agents*.md | claude.md | */claude.md | claude.local.md | */claude.local.md) return 1 ;;
    .claude/* | */.claude/* | .codex/* | */.codex/* | .agents/* | */.agents/*) return 1 ;;
  esac

  case "$worker" in
    test-gap)
      case "$1" in
        test/*) return 0 ;;
      esac
      ;;
    daily-cleanup)
      case "$1" in
        lib/* | test/* | docs/* | README.md) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# A blob with a NUL byte is binary, whatever .gitattributes says.
is_binary() {
  local blob_file size text_size
  blob_file="$(mktemp)" || exit 2
  if ! git cat-file blob "$1" >"$blob_file"; then
    rm -f "$blob_file"
    echo "cannot read blob $1" >&2
    exit 2
  fi
  size="$(wc -c <"$blob_file" | tr -d ' ')"
  text_size="$(tr -d '\000' <"$blob_file" | wc -c | tr -d ' ')"
  rm -f "$blob_file"
  [ "$size" != "$text_size" ]
}

# Run from the repository root so diff.relative cannot hide paths outside the cwd.
top="$(git rev-parse --show-toplevel)" || exit 2
cd "$top" || exit 2

# Resolve both ends to commit SHAs first, so an option-like or unknown argument
# is a git error (exit 2) rather than a flag that changes what git diff prints.
resolve_commit() {
  case "$1" in
    -*) return 1 ;;
  esac
  git rev-parse --verify --quiet --end-of-options "$1^{commit}"
}
if ! base_sha="$(resolve_commit "$base")" || ! head_sha="$(resolve_commit "$head")"; then
  echo "cannot resolve $base or $head to a commit" >&2
  exit 2
fi

raw_file="$(mktemp)" || exit 2
numstat_file="$(mktemp)" || exit 2
trap 'rm -f "$raw_file" "$numstat_file"' EXIT

# -z keeps paths byte for byte; --raw exposes file modes, --numstat --text removed
# lines even where attributes would mark a file binary.
# The flags override user config that would hide changes (diff.relative, diff.ignoreSubmodules).
diff_flags=(-z --no-renames --no-relative --ignore-submodules=none)
if ! git diff --raw --no-abbrev "${diff_flags[@]}" "$base_sha...$head_sha" >"$raw_file" ||
  ! git diff --numstat --text "${diff_flags[@]}" "$base_sha...$head_sha" >"$numstat_file"; then
  echo "git diff failed for $base...$head" >&2
  exit 2
fi

violations=0
while IFS= read -r -d '' meta; do
  if ! IFS= read -r -d '' path; then
    echo "malformed git diff output" >&2
    exit 2
  fi

  # meta is ":<old mode> <new mode> <old sha> <new sha> <status>"
  read -r old_mode new_mode old_sha new_sha status <<<"${meta#:}"
  reason=""

  if [ "$worker" = "test-gap" ] && [ "$status" = "D" ]; then
    reason="deletion"
  elif { [ "$new_mode" = "100644" ] && is_binary "$new_sha"; } ||
    { [ "$old_mode" = "100644" ] && is_binary "$old_sha"; }; then
    reason="binary"
  elif [ "$new_mode" = "120000" ] || [ "$old_mode" = "120000" ]; then
    reason="symlink"
  elif [ "$new_mode" = "160000" ] || [ "$old_mode" = "160000" ]; then
    reason="submodule"
  elif [ "$new_mode" != "100644" ] && [ "$new_mode" != "000000" ]; then
    reason="file mode $new_mode"
  elif [ "$old_mode" != "100644" ] && [ "$old_mode" != "000000" ]; then
    reason="file mode $old_mode"
  elif ! allowed_path "$path"; then
    reason="outside allowlist"
  fi

  if [ -n "$reason" ]; then
    printf '%s\t%s\t%s\n' "$status" "$reason" "$path"
    violations=$((violations + 1))
  fi
done <"$raw_file"

# Test reinforcement only adds tests, so it may not remove a line from any file.
if [ "$worker" = "test-gap" ]; then
  while IFS= read -r -d '' entry; do
    added="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    removed="${rest%%$'\t'*}"
    path="${rest#*$'\t'}"

    if [ "$added" = "-" ] || [ "$removed" = "-" ]; then
      printf '%s\t%s\t%s\n' "M" "binary" "$path"
      violations=$((violations + 1))
    elif [ "$removed" != "0" ]; then
      printf '%s\t%s\t%s\n' "M" "removed lines" "$path"
      violations=$((violations + 1))
    fi
  done <"$numstat_file"
fi

# On a case-insensitive checkout, test/Test_helper.exs overwrites test/test_helper.exs.
# Check the union of the base and head trees (files and directories) so a path main
# gained after the merge-base is compared too.
tree_file="$(mktemp)" || exit 2
trap 'rm -f "$raw_file" "$numstat_file" "$tree_file"' EXIT
if ! git ls-tree -r -t -z --name-only "$base_sha" >"$tree_file" ||
  ! git ls-tree -r -t -z --name-only "$head_sha" >>"$tree_file"; then
  echo "cannot list $base or $head" >&2
  exit 2
fi
collisions="$(tr '\000' '\n' <"$tree_file" | sort -u | tr '[:upper:]' '[:lower:]' | sort | uniq -d)"
if [ -n "$collisions" ]; then
  while IFS= read -r path; do
    printf '%s\t%s\t%s\n' "-" "case collision" "$path"
    violations=$((violations + 1))
  done <<<"$collisions"
fi

if [ "$violations" -gt 0 ]; then
  exit 1
fi

exit 0
