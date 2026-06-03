#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
CONF="$BASE/config"
[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"

tmp="$CONF.tmp"
{
    echo "ENABLED='0'"
    grep -v "^ENABLED=" "$CONF"
} > "$tmp"
mv "$tmp" "$CONF"

"$BASE/apply.sh"
