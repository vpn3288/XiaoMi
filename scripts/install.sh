#!/bin/sh
set -u

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HOST="$DEFAULT_HOST"
PORT="$DEFAULT_PORT"
DRY_RUN=0
AUTOSTART=1
ADMIN_TOKEN=""
UNINSTALL=0
INSTALL_EXISTED=0

generate_admin_token() {
    token=""
    if command -v od >/dev/null 2>&1; then
        token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    fi
    if [ -z "$token" ] && command -v hexdump >/dev/null 2>&1; then
        token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"' 2>/dev/null)"
    fi
    if [ -z "$token" ]; then
        token="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | dd bs=32 count=1 2>/dev/null)"
    fi
    [ -n "$token" ] || return 1
    printf '%s\n' "$token"
}

valid_admin_token() {
    echo "$1" | grep -Eq '^[A-Za-z0-9._-]{6,64}$'
}

write_admin_token() {
    dst="$1"
    value="$2"
    old_umask="$(umask)"
    umask 077
    if ! printf '%s\n' "$value" > "$dst"; then
        umask "$old_umask"
        return 1
    fi
    chmod 600 "$dst" 2>/dev/null || true
    umask "$old_umask"
}

copy_disabled_config() {
    src="$1"
    dst="$2"
    if ! {
        echo "ENABLED='0'"
        { [ -f "$src" ] && grep -v "^[[:space:]]*ENABLED=" "$src"; } || true
    } > "$dst"; then
        return 1
    fi
    return 0
}

disable_legacy_sidegw_panel() {
    router_root="${INSTALL_DIR%/toolbox}"
    seen_legacy=""
    for legacy_base in "$router_root/sidegw-panel" /mnt/*/xiaomi_router/sidegw-panel; do
        [ -d "$legacy_base" ] || continue
        [ "$legacy_base" = "$INSTALL_DIR/panel/modules/sidegw" ] && continue
        case " $seen_legacy " in
            *" $legacy_base "*) continue ;;
        esac
        seen_legacy="$seen_legacy $legacy_base"
        if [ -f "$legacy_base/config/sidegw.conf" ]; then
            legacy_tmp="$legacy_base/config/sidegw.conf.tmp.$$"
            copy_disabled_config "$legacy_base/config/sidegw.conf" "$legacy_tmp" ||
                die "cannot disable legacy sidegw config: $legacy_base"
            mv "$legacy_tmp" "$legacy_base/config/sidegw.conf" ||
                die "cannot replace legacy sidegw config: $legacy_base"
        fi
        if [ -f "$legacy_base/bin/sidegw-panel-start.sh" ]; then
            chmod a-x "$legacy_base/bin/sidegw-panel-start.sh" 2>/dev/null ||
                die "cannot disable legacy sidegw start script: $legacy_base"
        fi
        log "Disabled legacy sidegw panel: $legacy_base"
    done
}

usage() {
    cat <<EOF
Usage: sh scripts/install.sh [options]

Options:
  --dry-run              Show what would be done without changing files
  --install-dir PATH     Install directory, default: $DEFAULT_INSTALL_DIR
  --host IP              Panel listen IP, default: $DEFAULT_HOST
  --port PORT            Panel port, default: $DEFAULT_PORT
  --admin-token TOKEN    Set panel management token, 6-64 chars: A-Z a-z 0-9 . _ -
  --no-autostart         Do not register cron/firewall autostart
  --uninstall            Run scripts/uninstall.sh for this install dir
  --help                 Show this help

Safety:
  Install does not enable sidegw by default.
EOF
}

install_mount_dir() {
    rel="${INSTALL_DIR#/mnt/}"
    mount_name="${rel%%/*}"
    printf '/mnt/%s\n' "$mount_name"
}

preflight() {
    ensure_cmd ip
    ensure_cmd iptables
    ensure_cmd uci
    ensure_cmd uhttpd
    ensure_cmd pidof
    ensure_cmd netstat
    ensure_cmd awk
    ensure_cmd dd
    ensure_cmd tr
    ensure_cmd nslookup

    if [ -z "$ADMIN_TOKEN" ]; then
        generate_admin_token >/dev/null ||
            die "cannot generate admin token; install with --admin-token TOKEN"
    fi

    [ -d /sys/class/net/br-lan ] || die "br-lan not found; this installer expects Xiaomi/OpenWrt-like LAN bridge"

    mount_dir="$(install_mount_dir)"
    [ -d "$mount_dir" ] || die "USB mount path not found: $mount_dir"
    awk -v m="$mount_dir" '$2 == m { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts ||
        die "USB mount path is not mounted: $mount_dir"

    [ -d "$SCRIPT_DIR/../panel/www" ] || die "source panel/www missing"
    [ -d "$SCRIPT_DIR/../panel/modules/sidegw" ] || die "source sidegw module missing"
    [ -f "$SCRIPT_DIR/../panel/www/cgi-bin/sidegw.cgi" ] || die "source sidegw CGI missing"
    [ -f "$SCRIPT_DIR/../panel/www/cgi-bin/api.cgi" ] || die "source API CGI missing"
    [ -f "$SCRIPT_DIR/../panel/modules/sidegw/apply.sh" ] || die "source sidegw apply script missing"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --install-dir) shift; [ "$#" -gt 0 ] || die "--install-dir requires PATH"; INSTALL_DIR="$1" ;;
        --host) shift; [ "$#" -gt 0 ] || die "--host requires IP"; HOST="$1" ;;
        --port) shift; [ "$#" -gt 0 ] || die "--port requires PORT"; PORT="$1" ;;
        --admin-token) shift; [ "$#" -gt 0 ] || die "--admin-token requires TOKEN"; ADMIN_TOKEN="$1" ;;
        --no-autostart) AUTOSTART=0 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

is_ipv4 "$HOST" || die "invalid host IP: $HOST"
echo "$PORT" | grep -Eq '^[0-9]{1,5}$' || die "invalid port: $PORT"
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "invalid port: $PORT"
is_safe_install_dir "$INSTALL_DIR" || die "unsafe install dir: $INSTALL_DIR"
[ -z "$ADMIN_TOKEN" ] || valid_admin_token "$ADMIN_TOKEN" || die "invalid admin token; use 6-64 chars: A-Z a-z 0-9 . _ -"

if [ "$UNINSTALL" = "1" ]; then
    [ "$DRY_RUN" = "0" ] || die "--dry-run cannot be combined with --uninstall; run scripts/uninstall.sh after reviewing the install dir"
    exec sh "$SCRIPT_DIR/uninstall.sh" --install-dir "$INSTALL_DIR"
fi

log "Install dir: $INSTALL_DIR"
log "Panel URL: http://$HOST:$PORT/cgi-bin/sidegw.cgi"
log "Dry run: $DRY_RUN"
log "Autostart: $AUTOSTART"

preflight

if [ "$DRY_RUN" = "1" ]; then
    log "Dry run preflight passed. No changes were made."
    exit 0
fi

[ -f "$INSTALL_DIR/$INSTALL_MARKER" ] && INSTALL_EXISTED=1

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/log" "$INSTALL_DIR/config"
printf '%s\n' "$APP_NAME" > "$INSTALL_DIR/$INSTALL_MARKER" || die "cannot write install marker"
disable_legacy_sidegw_panel

keep_sidegw_config="/tmp/xiaomi-toolbox-sidegw-config.$$"
keep_sidegw_last_good="/tmp/xiaomi-toolbox-sidegw-last-good.$$"
keep_sidegw_rules_state="/tmp/xiaomi-toolbox-sidegw-rules-state.$$"
keep_sidegw_applied_config="/tmp/xiaomi-toolbox-sidegw-applied-config.$$"
keep_sidegw_pending_good="/tmp/xiaomi-toolbox-sidegw-pending-good.$$"
keep_sidegw_pending_until="/tmp/xiaomi-toolbox-sidegw-pending-until.$$"
keep_admin_token="/tmp/xiaomi-toolbox-admin-token.$$"
keep_cron_root="/tmp/xiaomi-toolbox-crontab-root.$$"
keep_firewall_config="/tmp/xiaomi-toolbox-firewall-config.$$"
RESTORE_ON_FAIL=0
AUTOSTART_TOUCHED=0
CRON_EXISTED=0
FIREWALL_EXISTED=0
panel_www_backup=""
sidegw_backup=""

cleanup_temp() {
    rm -f "$keep_sidegw_config" "$keep_sidegw_last_good" "$keep_sidegw_rules_state" \
        "$keep_sidegw_applied_config" "$keep_sidegw_pending_good" \
        "$keep_sidegw_pending_until" "$keep_admin_token" \
        "$keep_cron_root" "$keep_firewall_config"
}

restore_install_failure() {
    if [ "$AUTOSTART_TOUCHED" = "1" ]; then
        if [ "$CRON_EXISTED" = "1" ] && [ -f "$keep_cron_root" ]; then
            cat "$keep_cron_root" > /etc/crontabs/root 2>/dev/null || true
        elif [ "$CRON_EXISTED" = "0" ]; then
            rm -f /etc/crontabs/root 2>/dev/null || true
        fi
        if [ "$FIREWALL_EXISTED" = "1" ] && [ -f "$keep_firewall_config" ]; then
            cat "$keep_firewall_config" > /etc/config/firewall 2>/dev/null || true
            uci commit firewall >/dev/null 2>&1 || true
        elif [ "$FIREWALL_EXISTED" = "0" ]; then
            uci -q delete "firewall.$FIREWALL_SECTION" 2>/dev/null || true
            uci commit firewall >/dev/null 2>&1 || true
        fi
    fi
    if [ "$INSTALL_EXISTED" = "0" ]; then
        log "Cleaning up failed first-time install: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR/panel" 2>/dev/null || true
        rm -f "$INSTALL_DIR/toolbox-bootstrap.sh" "$INSTALL_DIR/config/toolbox.conf" "$INSTALL_DIR/$INSTALL_MARKER" 2>/dev/null || true
        rmdir "$INSTALL_DIR/config" "$INSTALL_DIR/log" "$INSTALL_DIR" 2>/dev/null || true
    fi
    [ "$RESTORE_ON_FAIL" = "1" ] || return 0
    if [ -n "$panel_www_backup" ] && [ -d "$panel_www_backup" ]; then
        rm -rf "$INSTALL_DIR/panel/www" 2>/dev/null || true
        mv "$panel_www_backup" "$INSTALL_DIR/panel/www" 2>/dev/null || true
    fi
    if [ -n "$sidegw_backup" ] && [ -d "$sidegw_backup" ]; then
        rm -rf "$INSTALL_DIR/panel/modules/sidegw" 2>/dev/null || true
        mv "$sidegw_backup" "$INSTALL_DIR/panel/modules/sidegw" 2>/dev/null || true
    fi
}

on_exit() {
    status="$?"
    if [ "$status" -ne 0 ]; then
        restore_install_failure
    fi
    cleanup_temp
}
trap on_exit EXIT

restore_temp_file() {
    src="$1"
    dst="$2"
    label="$3"
    [ -f "$src" ] || return 0
    if ! cp "$src" "$dst"; then
        die "cannot restore $label to $dst"
    fi
    rm -f "$src"
}

restore_disabled_temp_file() {
    src="$1"
    dst="$2"
    label="$3"
    [ -f "$src" ] || return 0
    if ! copy_disabled_config "$src" "$dst"; then
        die "cannot restore disabled $label to $dst"
    fi
    rm -f "$src"
}

if [ -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config" "$keep_sidegw_config" || die "cannot preserve sidegw config"
elif [ -f "$INSTALL_DIR/config/sidegw.config" ]; then
    copy_disabled_config "$INSTALL_DIR/config/sidegw.config" "$keep_sidegw_config" || die "cannot preserve sidegw config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config.last_good" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.last_good" "$keep_sidegw_last_good" || die "cannot preserve sidegw last-good config"
elif [ -f "$INSTALL_DIR/config/sidegw.last_good" ]; then
    cp "$INSTALL_DIR/config/sidegw.last_good" "$keep_sidegw_last_good" || die "cannot preserve sidegw last-good config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/rules.state" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/rules.state" "$keep_sidegw_rules_state" || die "cannot preserve sidegw rules state"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config.applied" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.applied" "$keep_sidegw_applied_config" || die "cannot preserve sidegw applied config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config.pending_good" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.pending_good" "$keep_sidegw_pending_good" || die "cannot preserve sidegw pending config"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/config.pending_until" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.pending_until" "$keep_sidegw_pending_until" || die "cannot preserve sidegw pending deadline"
fi
if [ -f "$INSTALL_DIR/panel/modules/sidegw/admin.token" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/admin.token" "$keep_admin_token" || die "cannot preserve admin token"
elif [ -f "$INSTALL_DIR/config/admin.token" ]; then
    cp "$INSTALL_DIR/config/admin.token" "$keep_admin_token" || die "cannot preserve admin token"
fi

if [ -e "$INSTALL_DIR/panel/www" ]; then
    panel_www_backup="$INSTALL_DIR/panel/www.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)-$$"
    mv "$INSTALL_DIR/panel/www" "$panel_www_backup" || die "cannot move backup $INSTALL_DIR/panel/www"
    RESTORE_ON_FAIL=1
fi
if [ -e "$INSTALL_DIR/panel/modules/sidegw" ]; then
    sidegw_backup="$INSTALL_DIR/panel/modules/sidegw.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)-$$"
    mv "$INSTALL_DIR/panel/modules/sidegw" "$sidegw_backup" || die "cannot move backup $INSTALL_DIR/panel/modules/sidegw"
    RESTORE_ON_FAIL=1
fi
backup_file "$INSTALL_DIR/config/toolbox.conf"
backup_file "$INSTALL_DIR/toolbox-bootstrap.sh"

mkdir -p "$INSTALL_DIR/panel/www" "$INSTALL_DIR/panel/modules" || die "cannot create panel directories"

cp -R "$SCRIPT_DIR/../panel/www/." "$INSTALL_DIR/panel/www/" || die "cannot copy panel web files"
mkdir -p "$INSTALL_DIR/panel/modules/sidegw" || die "cannot create sidegw module directory"
cp -R "$SCRIPT_DIR/../panel/modules/sidegw/." "$INSTALL_DIR/panel/modules/sidegw/" || die "cannot copy sidegw module files"
chmod -R a+rX "$INSTALL_DIR/panel/www" "$INSTALL_DIR/panel/modules/sidegw" 2>/dev/null || true
chmod +x "$INSTALL_DIR/panel/www/cgi-bin/"*.cgi 2>/dev/null || true
chmod +x "$INSTALL_DIR/panel/modules/sidegw/"*.sh 2>/dev/null || true
[ -s "$INSTALL_DIR/panel/www/index.html" ] || die "panel index missing after copy"
[ -x "$INSTALL_DIR/panel/www/cgi-bin/sidegw.cgi" ] || die "panel cgi missing or not executable after copy"
[ -x "$INSTALL_DIR/panel/www/cgi-bin/api.cgi" ] || die "api cgi missing or not executable after copy"
[ -x "$INSTALL_DIR/panel/modules/sidegw/apply.sh" ] || die "sidegw apply script missing or not executable after copy"
[ -x "$INSTALL_DIR/panel/modules/sidegw/test.sh" ] || die "sidegw test script missing or not executable after copy"
[ -x "$INSTALL_DIR/panel/modules/sidegw/rollback.sh" ] || die "sidegw rollback script missing or not executable after copy"

cat > "$INSTALL_DIR/config/toolbox.conf" <<EOF
INSTALL_DIR='$INSTALL_DIR'
HOST='$HOST'
PORT='$PORT'
EOF
[ -s "$INSTALL_DIR/config/toolbox.conf" ] || die "cannot write toolbox config"

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

find_port_uhttpd() {
    netstat -lntp 2>/dev/null |
        awk -v listen=":\$PORT" '\$0 ~ /LISTEN/ && \$0 ~ /uhttpd/ && \$4 ~ listen "\$" {
            split(\$NF, p, "/")
            if (p[1] ~ /^[0-9]+$/) {
                print p[1]
                exit
            }
        }'
}

stop_replaceable_port_uhttpd() {
    port_pid="\$(find_port_uhttpd)"
    [ -n "\$port_pid" ] || return 0
    cmdline="\$(tr '\000' ' ' < "/proc/\$port_pid/cmdline" 2>/dev/null)"
    case "\$cmdline" in
        *xiaomi*toolbox*|*XiaoMi*|*sidegw*|*"\$INSTALL_DIR"*)
            kill "\$port_pid" 2>/dev/null || true
            sleep 1
            kill -0 "\$port_pid" 2>/dev/null && kill -9 "\$port_pid" 2>/dev/null || true
            ;;
        *)
            echo "port \$HOST:\$PORT is already used by PID \$port_pid: \$cmdline" >&2
            return 1
            ;;
    esac
}

sidegw_config_enabled() {
    [ -f "\$SIDEGW_BASE/config" ] || return 1
    grep -Eq "^[[:space:]]*ENABLED=['\"]?1['\"]?[[:space:]]*\$" "\$SIDEGW_BASE/config"
}

now="\$(date +%s 2>/dev/null || echo 0)"
pending_until="\$(cat "\$PENDING_UNTIL" 2>/dev/null || echo 0)"

if echo "\$pending_until" | grep -Eq '^[0-9]+$' && [ -f "\$PENDING_GOOD" ] && [ "\$now" -le "\$pending_until" ]; then
    SIDEGW_CONFIG="\$PENDING_GOOD" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
elif [ -f "\$PENDING_GOOD" ] || [ -f "\$PENDING_UNTIL" ]; then
    if [ -f "\$SIDEGW_BASE/config.last_good" ]; then
        cp "\$SIDEGW_BASE/config.last_good" "\$SIDEGW_BASE/config" 2>/dev/null || true
        if SIDEGW_CONFIG="\$SIDEGW_BASE/config.last_good" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1; then
            rm -f "\$PENDING_GOOD" "\$PENDING_UNTIL"
        fi
    elif [ -x "\$SIDEGW_BASE/apply.sh" ]; then
        cp "\$SIDEGW_BASE/config.default" "\$SIDEGW_BASE/config" 2>/dev/null || true
        if SIDEGW_CONFIG="\$SIDEGW_BASE/config.default" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1; then
            rm -f "\$PENDING_GOOD" "\$PENDING_UNTIL"
        fi
    fi
elif [ -f "\$SIDEGW_BASE/config.last_good" ] && sidegw_config_enabled; then
    SIDEGW_CONFIG="\$SIDEGW_BASE/config.last_good" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
elif [ -x "\$SIDEGW_BASE/apply.sh" ]; then
    if sidegw_config_enabled; then
        echo "refusing to apply unverified enabled sidegw config" >/tmp/xiaomi-toolbox-sidegw.log
        SIDEGW_CONFIG="\$SIDEGW_BASE/config.default" "\$SIDEGW_BASE/apply.sh" >>/tmp/xiaomi-toolbox-sidegw.log 2>&1
    else
        SIDEGW_CONFIG="\$SIDEGW_BASE/config" "\$SIDEGW_BASE/apply.sh" >/tmp/xiaomi-toolbox-sidegw.log 2>&1
    fi
fi

running_pid="\$(find_toolbox_uhttpd)"
if [ -n "\$running_pid" ] && kill -0 "\$running_pid" 2>/dev/null; then
    echo "\$running_pid" > "\$PID_FILE"
    :
else
    stop_replaceable_port_uhttpd || exit 1
    "\$UHTTPD_BIN" -p "\$HOST:\$PORT" -h "\$INSTALL_DIR/panel/www" -I index.html -x /cgi-bin -t 60 -T 30 -D
    sleep 1
    if ! find_toolbox_uhttpd > "\$PID_FILE" 2>/dev/null; then
        rm -f "\$PID_FILE"
        echo "failed to start toolbox uhttpd on \$HOST:\$PORT" >&2
        exit 1
    fi
fi
EOF
[ -s "$INSTALL_DIR/toolbox-bootstrap.sh" ] || die "cannot write toolbox bootstrap"
chmod +x "$INSTALL_DIR/toolbox-bootstrap.sh" || die "cannot make toolbox bootstrap executable"

if [ -f "$keep_sidegw_config" ]; then
    if [ -f "$keep_sidegw_last_good" ] || [ -f "$keep_sidegw_pending_good" ]; then
        restore_temp_file "$keep_sidegw_config" "$INSTALL_DIR/panel/modules/sidegw/config" "sidegw config"
    else
        restore_disabled_temp_file "$keep_sidegw_config" "$INSTALL_DIR/panel/modules/sidegw/config" "sidegw config"
    fi
elif [ ! -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
    cp "$INSTALL_DIR/panel/modules/sidegw/config.default" "$INSTALL_DIR/panel/modules/sidegw/config" ||
        die "cannot create default sidegw config"
fi
if [ -f "$keep_sidegw_last_good" ]; then
    restore_temp_file "$keep_sidegw_last_good" "$INSTALL_DIR/panel/modules/sidegw/config.last_good" "sidegw last-good config"
fi
if [ -f "$keep_sidegw_rules_state" ]; then
    restore_temp_file "$keep_sidegw_rules_state" "$INSTALL_DIR/panel/modules/sidegw/rules.state" "sidegw rules state"
fi
if [ -f "$keep_sidegw_applied_config" ]; then
    restore_temp_file "$keep_sidegw_applied_config" "$INSTALL_DIR/panel/modules/sidegw/config.applied" "sidegw applied config"
fi
if [ -f "$keep_sidegw_pending_good" ]; then
    restore_temp_file "$keep_sidegw_pending_good" "$INSTALL_DIR/panel/modules/sidegw/config.pending_good" "sidegw pending config"
fi
if [ -f "$keep_sidegw_pending_until" ]; then
    restore_temp_file "$keep_sidegw_pending_until" "$INSTALL_DIR/panel/modules/sidegw/config.pending_until" "sidegw pending deadline"
fi
if [ -n "$ADMIN_TOKEN" ]; then
    write_admin_token "$INSTALL_DIR/panel/modules/sidegw/admin.token" "$ADMIN_TOKEN" || die "cannot write admin token"
elif [ -f "$keep_admin_token" ]; then
    restore_temp_file "$keep_admin_token" "$INSTALL_DIR/panel/modules/sidegw/admin.token" "admin token"
    chmod 600 "$INSTALL_DIR/panel/modules/sidegw/admin.token" 2>/dev/null || true
fi
if [ ! -f "$INSTALL_DIR/panel/modules/sidegw/admin.token" ]; then
    new_admin_token="$(generate_admin_token)" || die "cannot generate strong admin token; pass --admin-token explicitly"
    write_admin_token "$INSTALL_DIR/panel/modules/sidegw/admin.token" "$new_admin_token" || die "cannot write admin token"
fi

if [ "$AUTOSTART" = "1" ]; then
    AUTOSTART_TOUCHED=1
    if [ -f /etc/crontabs/root ]; then
        CRON_EXISTED=1
        cp /etc/crontabs/root "$keep_cron_root" || die "cannot preserve /etc/crontabs/root"
    fi
    if [ -f /etc/config/firewall ]; then
        FIREWALL_EXISTED=1
        cp /etc/config/firewall "$keep_firewall_config" || die "cannot preserve /etc/config/firewall"
    fi

    backup_file /etc/crontabs/root
    cron_tmp="/tmp/xiaomi-toolbox-cron.$$"
    if [ -f /etc/crontabs/root ]; then
        grep -v "$CRON_MARK" /etc/crontabs/root > "$cron_tmp"
        grep_status="$?"
        [ "$grep_status" -le 1 ] || die "cannot prepare crontab update"
    else
        : > "$cron_tmp" || die "cannot prepare crontab update"
    fi
    echo "* * * * * $INSTALL_DIR/toolbox-bootstrap.sh >/dev/null 2>&1 $CRON_MARK" >> "$cron_tmp" ||
        die "cannot append toolbox cron entry"
    cat "$cron_tmp" > /etc/crontabs/root || die "cannot write /etc/crontabs/root"
    rm -f "$cron_tmp"
    /etc/init.d/cron restart >/dev/null 2>&1 || true

    backup_file /etc/config/firewall
    uci set "firewall.$FIREWALL_SECTION=include" || die "cannot set firewall include"
    uci set "firewall.$FIREWALL_SECTION.type=script" || die "cannot set firewall include type"
    uci set "firewall.$FIREWALL_SECTION.path=$INSTALL_DIR/toolbox-bootstrap.sh" || die "cannot set firewall include path"
    uci set "firewall.$FIREWALL_SECTION.enabled=1" || die "cannot enable firewall include"
    uci commit firewall || die "cannot commit firewall config"
fi

"$INSTALL_DIR/toolbox-bootstrap.sh" || die "failed to start toolbox panel"
RESTORE_ON_FAIL=0

log "Installed."
log "Open: http://$HOST:$PORT/cgi-bin/sidegw.cgi"
log "Home: http://$HOST:$PORT/"
log "Panel management token: $(cat "$INSTALL_DIR/panel/modules/sidegw/admin.token")"
log "Keep this token. The panel requires it for save/apply/confirm/disable actions."
if grep -Eq "^[[:space:]]*ENABLED=['\"]?1['\"]?[[:space:]]*$" "$INSTALL_DIR/panel/modules/sidegw/config" &&
    [ -f "$INSTALL_DIR/panel/modules/sidegw/config.last_good" ]; then
    log "sidegw verified config was preserved from an existing install; check the panel before changing it."
else
    log "sidegw is installed with the current config disabled until you enable it in the panel."
fi
