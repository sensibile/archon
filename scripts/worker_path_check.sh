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
  case "$worker" in
    test-gap)
      case "$1" in
        test/*) return 0 ;;
      esac
      ;;
    daily-cleanup)
      case "$1" in
        docs/adr/* | docs/operations.md) return 1 ;;
        lib/* | test/* | docs/* | README.md) return 0 ;;
      esac
      ;;
  esac
  return 1
}

raw_file="$(mktemp)" || exit 2
trap 'rm -f "$raw_file"' EXIT

# -z keeps paths byte for byte; --raw exposes file modes for symlinks and submodules.
if ! git diff --raw -z --no-renames --no-abbrev "$base...$head" >"$raw_file"; then
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
  read -r old_mode new_mode _old_sha _new_sha status <<<"${meta#:}"
  reason=""

  if [ "$worker" = "test-gap" ] && [ "$status" = "D" ]; then
    reason="deletion"
  elif [ "$new_mode" = "120000" ] || [ "$old_mode" = "120000" ]; then
    reason="symlink"
  elif [ "$new_mode" = "160000" ] || [ "$old_mode" = "160000" ]; then
    reason="submodule"
  elif ! allowed_path "$path"; then
    reason="outside allowlist"
  fi

  if [ -n "$reason" ]; then
    printf '%s\t%s\t%s\n' "$status" "$reason" "$path"
    violations=$((violations + 1))
  fi
done <"$raw_file"

if [ "$violations" -gt 0 ]; then
  exit 1
fi

exit 0
