#!/bin/sh

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "$0")" && pwd)"

case "${QUERY_STRING:-}" in
    module=sidegw*|*'&module=sidegw'*)
        exec "$SCRIPT_DIR/sidegw.cgi"
        ;;
esac

cat <<'EOF'
Content-Type: text/plain; charset=utf-8

xiaomi-toolbox api
sidegw: /cgi-bin/sidegw.cgi
EOF
