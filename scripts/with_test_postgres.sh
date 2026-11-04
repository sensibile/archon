#!/usr/bin/env bash
# Runs one command against a disposable Postgres container, for the validation-health suites in
# .taeguk/validation-suites.toml. See docs/operations.md "검증 건강도" and ADR 0029.
#
# Usage: bash scripts/with_test_postgres.sh <command> [args...]
#
# The image is the one CI's postgres service uses (.github/workflows/ci.yml). The port is a random
# one on 127.0.0.1, the password ARCHON_TEST_PG_PASSWORD (validation_health.py passes its redacted
# {secret}) or a fresh one. The command runs with DATABASE_URL and ARCHON_REQUIRE_POSTGRES=1, and
# the container is removed when this script exits. A SIGKILL skips that removal, so the run that
# called this removes its leftover archon-validation-health-* containers at the end.
#
# Exit codes: the command's own, 2 usage or no image, 3 the container did not start or get ready.

set -u

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

top="$(git rev-parse --show-toplevel)" || exit 2
image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(postgres:[^[:space:]]*\)[[:space:]]*$/\1/p' \
  "$top/.github/workflows/ci.yml" | head -n 1)"
if [ -z "$image" ]; then
  echo "no postgres image in .github/workflows/ci.yml" >&2
  exit 2
fi

password="${ARCHON_TEST_PG_PASSWORD:-$(openssl rand -hex 24)}"
# The password goes into a URL unescaped.
case "$password" in
  "" | *[!A-Za-z0-9_-]*)
    echo "ARCHON_TEST_PG_PASSWORD must be non-empty and URL-safe" >&2
    exit 2
    ;;
esac

name="archon-validation-health-$(date +%Y%m%d-%H%M%S)-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM HUP

echo "postgres: $image as $name"
# Passed by name only, so the password is not on a command line.
if ! POSTGRES_PASSWORD="$password" docker run --detach --name "$name" --env POSTGRES_PASSWORD \
  --publish 127.0.0.1::5432 "$image" >/dev/null; then
  echo "docker run failed" >&2
  exit 3
fi

# Ready over TCP: during initialization the image runs a temporary socket-only server.
ready=""
for _ in $(seq 60); do
  if docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres; then
    ready=1
    break
  fi
  sleep 1
done
port="$(docker port "$name" 5432/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
if [ -z "$ready" ] || [ -z "$port" ]; then
  echo "postgres did not become ready on 127.0.0.1 within 60s" >&2
  exit 3
fi

DATABASE_URL="ecto://postgres:$password@127.0.0.1:$port/archon_test" ARCHON_REQUIRE_POSTGRES=1 "$@"
