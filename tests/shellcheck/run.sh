#!/bin/sh
set -u

ROOT="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

FILES="$(find scripts panel -type f \( -name '*.sh' -o -name '*.cgi' \) | sort)"
STATUS=0

for file in $FILES; do
    printf 'sh -n %s\n' "$file"
    sh -n "$file" || STATUS=1
done

if [ "${RUN_SHELLCHECK:-0}" = "1" ] && command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck %s\n' "$FILES"
    shellcheck -s sh $FILES || STATUS=1
elif [ "${RUN_SHELLCHECK:-0}" = "1" ]; then
    printf '%s\n' 'shellcheck: skipped (not installed)'
else
    printf '%s\n' 'shellcheck: skipped (set RUN_SHELLCHECK=1 to enable)'
fi

exit "$STATUS"
