#!/bin/sh
set -u

ROOT="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

FILES_FILE="/tmp/xiaomi-toolbox-shell-files.$$"
STATUS=0

cleanup() {
    rm -f "$FILES_FILE"
}
trap cleanup EXIT INT TERM

find scripts panel -type f \( -name '*.sh' -o -name '*.cgi' \) | sort > "$FILES_FILE" || exit 1

while IFS= read -r file; do
    printf 'sh -n %s\n' "$file"
    sh -n "$file" || STATUS=1
done < "$FILES_FILE"

if [ "${RUN_SHELLCHECK:-0}" = "1" ] && command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r file; do
        printf 'shellcheck %s\n' "$file"
        shellcheck -s sh "$file" || STATUS=1
    done < "$FILES_FILE"
elif [ "${RUN_SHELLCHECK:-0}" = "1" ]; then
    printf '%s\n' 'shellcheck: skipped (not installed)'
else
    printf '%s\n' 'shellcheck: skipped (set RUN_SHELLCHECK=1 to enable)'
fi

exit "$STATUS"
