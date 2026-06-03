#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
DRY_RUN=0
AUTOSTART=1

generate_admin_token() {
    token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    if [ -n "$token" ]; then
        printf '%s\n' "$token"
    else
        printf '%s%s\n' "$(date +%s 2>/dev/null || echo now)" "$$"
    fi
}

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
        --install-dir) shift; [ "$#" -gt 0 ] || die "--install-dir requires PATH"; INSTALL_DIR="$1" ;;
        --host) shift; [ "$#" -gt 0 ] || die "--host requires IP"; HOST="$1" ;;
        --port) shift; [ "$#" -gt 0 ] || die "--port requires PORT"; PORT="$1" ;;
        --no-autostart) AUTOSTART=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

is_ipv4 "$HOST" || die "invalid host IP: $HOST"
echo "$PORT" | grep -Eq '^[0-9]{1,5}$' || die "invalid port: $PORT"
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "invalid port: $PORT"
is_safe_install_dir "$INSTALL_DIR" || die "unsafe install dir: $INSTALL_DIR"

log "Install dir: $INSTALL_DIR"
log "Panel URL: http://$HOST:$PORT/"
log "Dry run: $DRY_RUN"
log "Autostart: $AUTOSTART"

if [ "$DRY_RUN" = "1" ]; then
    log "Dry run complete. No changes were made."
    exit 0
fi

ensure_cmd ip
ensure_cmd iptables
ensure_cmd uci
ensure_cmd uhttpd
ensure_cmd pidof

[ -d /sys/class/net/br-lan ] || die "br-lan not found; this installer expects Xiaomi/OpenWrt-like LAN bridge"

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/log" "$INSTALL_DIR/config"
printf '%s\n' "$APP_NAME" > "$INSTALL_DIR/$INSTALL_MARKER" || die "cannot write install marker"

keep_sidegw_config="/tmp/xiaomi-toolbox-sidegw-config.$$"
keep_sidegw_last_good="/tmp/xiaomi-toolbox-sidegw-last-good.$$"
keep_admin_token="/tmp/xiaomi-toolbox-admin-token.$$"
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config" "$keep_sidegw_config" || die "cannot preserve sidegw config"
elif [ -f "$INSTALL_DIR/config/sidegw.config" ]; then
    cp "$INSTALL_DIR/config/sidegw.config" "$keep_sidegw_config" || die "cannot preserve sidegw config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config.last_good" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.last_good" "$keep_sidegw_last_good" || die "cannot preserve sidegw last-good config"
elif [ -f "$INSTALL_DIR/config/sidegw.last_good" ]; then
    cp "$INSTALL_DIR/config/sidegw.last_good" "$keep_sidegw_last_good" || die "cannot preserve sidegw last-good config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/admin.token" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/admin.token" "$keep_admin_token" || die "cannot preserve admin token"
elif [ -f "$INSTALL_DIR/config/admin.token" ]; then
    cp "$INSTALL_DIR/config/admin.token" "$keep_admin_token" || die "cannot preserve admin token"
fi

backup_path_move "$INSTALL_DIR/panel/www"
backup_path_move "$INSTALL_DIR/panel/modules/sidegw"
backup_file "$INSTALL_DIR/config/toolbox.conf"
backup_file "$INSTALL_DIR/toolbox-bootstrap.sh"

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

UHTTPD_BIN="$(command -v uhttpd)"
cat > "$INSTALL_DIR/toolbox-bootstrap.sh" <<EOF
#!/bin/sh
INSTALL_DIR='$INSTALL_DIR'
HOST='$HOST'
PORT='$PORT'
UHTTPD_BIN='$UHTTPD_BIN'
PID_FILE='/var/run/xiaomi-toolbox.pid'
SIDEGW_BASE="\$INSTALL_DIR/panel/modules/sidegw"
PENDING_GOOD="\$SIDEGW_BASE/config.pending_good"
PENDING_UNTIL="\$SIDEGW_BASE/config.pending_until"

find_toolbox_uhttpd() {
    for pid in \$(pidof uhttpd 2>/dev/null); do
        cmdline="\$(tr '\000' ' ' < "/proc/\$pid/cmdline" 2>/dev/null)"
        case "\$cmdline" in
            *"\$INSTALL_DIR/panel/www"*)
                echo "\$pid"
                return 0
                ;;
        esac
    done
    return 1
}

now="\$(date +%s 2>/dev/null || echo 0)"
pending_until="\$(cat "\$PENDING_UNTIL" 2>/dev/null || echo 0)"

if echo "\$pending_until" | grep -Eq '^[0-9]+$' && [ -f "\$PENDING_GOOD" ] && [ "\$now" -le "\$pending_until" ]; then
    SIDEGW_CONFIG="\$PENDING_GOOD" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
elif [ -f "\$SIDEGW_BASE/config.last_good" ]; then
    rm -f "\$PENDING_GOOD" "\$PENDING_UNTIL"
    SIDEGW_CONFIG="\$SIDEGW_BASE/config.last_good" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
elif [ -x "\$SIDEGW_BASE/apply.sh" ]; then
    rm -f "\$PENDING_GOOD" "\$PENDING_UNTIL"
    SIDEGW_CONFIG="\$SIDEGW_BASE/config.default" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
fi

running_pid="\$(find_toolbox_uhttpd)"
if [ -n "\$running_pid" ] && kill -0 "\$running_pid" 2>/dev/null; then
    echo "\$running_pid" > "\$PID_FILE"
    :
else
    "\$UHTTPD_BIN" -p "\$HOST:\$PORT" -h "\$INSTALL_DIR/panel/www" -x /cgi-bin -t 60 -T 30 -D
    sleep 1
    find_toolbox_uhttpd > "\$PID_FILE" 2>/dev/null || rm -f "\$PID_FILE"
fi
EOF
chmod +x "$INSTALL_DIR/toolbox-bootstrap.sh"

if [ -f "$keep_sidegw_config" ]; then
    mv "$keep_sidegw_config" "$INSTALL_DIR/panel/modules/sidegw/config"
elif [ ! -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.default" "$INSTALL_DIR/panel/modules/sidegw/config"
fi
if [ -f "$keep_sidegw_last_good" ]; then
    mv "$keep_sidegw_last_good" "$INSTALL_DIR/panel/modules/sidegw/config.last_good"
fi
if [ -f "$keep_admin_token" ]; then
    mv "$keep_admin_token" "$INSTALL_DIR/panel/modules/sidegw/admin.token"
fi
if [ ! -f "$INSTALL_DIR/panel/modules/sidegw/admin.token" ]; then
    old_umask="$(umask)"
    umask 077
    generate_admin_token > "$INSTALL_DIR/panel/modules/sidegw/admin.token" || die "cannot write admin token"
    umask "$old_umask"
fi

if [ "$AUTOSTART" = "1" ]; then
    backup_file /etc/crontabs/root
    grep -v "$CRON_MARK" /etc/crontabs/root 2>/dev/null > /tmp/xiaomi-toolbox-cron || true
    echo "* * * * * $INSTALL_DIR/toolbox-bootstrap.sh >/dev/null 2>&1 $CRON_MARK" >> /tmp/xiaomi-toolbox-cron
    cat /tmp/xiaomi-toolbox-cron > /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true

    backup_file /etc/config/firewall
    uci set firewall.$FIREWALL_SECTION='include'
    uci set firewall.$FIREWALL_SECTION.type='script'
    uci set firewall.$FIREWALL_SECTION.path="$INSTALL_DIR/toolbox-bootstrap.sh"
    uci set firewall.$FIREWALL_SECTION.enabled='1'
    uci commit firewall
fi

"$INSTALL_DIR/toolbox-bootstrap.sh"

log "Installed."
log "Open: http://$HOST:$PORT/"
log "Panel management token: $(cat "$INSTALL_DIR/panel/modules/sidegw/admin.token")"
log "Keep this token. The panel requires it for save/apply/confirm/disable actions."
log "sidegw is installed but remains disabled until you enable it in the panel."
