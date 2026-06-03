#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
DRY_RUN=0
AUTOSTART=1

usage() {
    cat <<EOF
Usage: sh scripts/install.sh [options]

Options:
  --dry-run              Show what would be done without changing files
  --install-dir PATH     Install directory, default: $DEFAULT_INSTALL_DIR
  --host IP              Panel listen IP, default: $DEFAULT_HOST
  --port PORT            Panel port, default: $DEFAULT_PORT
  --no-autostart         Do not register cron/firewall autostart
  --help                 Show this help

Safety:
  Install does not enable sidegw by default.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --install-dir) shift; INSTALL_DIR="${1:-}" ;;
        --host) shift; HOST="${1:-}" ;;
        --port) shift; PORT="${1:-}" ;;
        --no-autostart) AUTOSTART=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

is_ipv4 "$HOST" || die "invalid host IP: $HOST"
echo "$PORT" | grep -Eq '^[0-9]{1,5}$' || die "invalid port: $PORT"

ensure_cmd ip
ensure_cmd iptables
ensure_cmd uci
ensure_cmd uhttpd

[ -d /sys/class/net/br-lan ] || die "br-lan not found; this installer expects Xiaomi/OpenWrt-like LAN bridge"

log "Install dir: $INSTALL_DIR"
log "Panel URL: http://$HOST:$PORT/"
log "Dry run: $DRY_RUN"
log "Autostart: $AUTOSTART"

if [ "$DRY_RUN" = "1" ]; then
    log "Dry run complete. No changes were made."
    exit 0
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/log" "$INSTALL_DIR/config"
mkdir -p "$INSTALL_DIR/panel/www" "$INSTALL_DIR/panel/modules"

cp -R "$SCRIPT_DIR/../panel/www/." "$INSTALL_DIR/panel/www/"
mkdir -p "$INSTALL_DIR/panel/modules/sidegw"
cp -R "$SCRIPT_DIR/../panel/modules/sidegw/." "$INSTALL_DIR/panel/modules/sidegw/"
chmod +x "$INSTALL_DIR/panel/www/cgi-bin/"*.cgi 2>/dev/null || true
chmod +x "$INSTALL_DIR/panel/modules/sidegw/"*.sh 2>/dev/null || true

cat > "$INSTALL_DIR/config/toolbox.conf" <<EOF
INSTALL_DIR='$INSTALL_DIR'
HOST='$HOST'
PORT='$PORT'
EOF

cat > "$INSTALL_DIR/toolbox-bootstrap.sh" <<EOF
#!/bin/sh
INSTALL_DIR='$INSTALL_DIR'
HOST='$HOST'
PORT='$PORT'

[ -x "\$INSTALL_DIR/panel/modules/sidegw/apply.sh" ] && "\$INSTALL_DIR/panel/modules/sidegw/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1

if ! netstat -lnp 2>/dev/null | grep -q "\$HOST:\$PORT.*uhttpd"; then
    kill "\$(cat /var/run/xiaomi-toolbox.pid 2>/dev/null)" 2>/dev/null || true
    /usr/sbin/uhttpd -p "\$HOST:\$PORT" -h "\$INSTALL_DIR/panel/www" -x /cgi-bin -t 60 -T 30 -D
    pgrep -f "uhttpd -p \$HOST:\$PORT" | head -n 1 > /var/run/xiaomi-toolbox.pid
fi
EOF
chmod +x "$INSTALL_DIR/toolbox-bootstrap.sh"

if [ ! -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.default" "$INSTALL_DIR/panel/modules/sidegw/config"
fi

if [ "$AUTOSTART" = "1" ]; then
    backup_file /etc/crontabs/root
    grep -v "$CRON_MARK" /etc/crontabs/root 2>/dev/null > /tmp/xiaomi-toolbox-cron || true
    echo "* * * * * $INSTALL_DIR/toolbox-bootstrap.sh >/dev/null 2>&1 $CRON_MARK" >> /tmp/xiaomi-toolbox-cron
    cat /tmp/xiaomi-toolbox-cron > /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true

    uci set firewall.$FIREWALL_SECTION='include'
    uci set firewall.$FIREWALL_SECTION.type='script'
    uci set firewall.$FIREWALL_SECTION.path="$INSTALL_DIR/toolbox-bootstrap.sh"
    uci set firewall.$FIREWALL_SECTION.enabled='1'
    uci commit firewall
fi

"$INSTALL_DIR/toolbox-bootstrap.sh"

log "Installed."
log "Open: http://$HOST:$PORT/"
log "sidegw is installed but remains disabled until you enable it in the panel."
