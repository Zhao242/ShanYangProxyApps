#!/bin/sh
# KOMARI_AGENT_MANAGER=1
# Self-contained manager: workers run in independent shells so their
# errexit/rollback traps remain effective when the menu handles failures.

manager_check_cancel() {
    case "$1" in q|Q) exit 10 ;; esac
}

manager_fetch_file() {
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 180 --retry 2 \
            --output "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 180 -O "$1" "$2"
    else
        fail "需要 curl 或 wget 才能从 GitHub 下载 Agent"
    fi
}

manager_download_agent() {
    case "$1" in
        amd64|arm64) ;;
        *) fail "不支持的 Agent 架构：$1" ;;
    esac
    command -v sha1sum >/dev/null 2>&1 || fail "缺少 sha1sum，无法校验 GitHub 文件"
    command -v wc >/dev/null 2>&1 || fail "缺少 wc，无法校验 GitHub 文件"
    MANAGER_DOWNLOAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/komari-agent-download.XXXXXX") ||
        fail "无法创建 Agent 下载临时目录"
    SOURCE_BINARY="$MANAGER_DOWNLOAD_DIR/agent"
    download_metadata="$MANAGER_DOWNLOAD_DIR/metadata.json"
    download_name="komari-agent-linux-$1"
    download_api="https://api.github.com/repos/Zhao242/ShanYangProxyApps/contents/Tz/$download_name?ref=main"
    download_raw="https://raw.githubusercontent.com/Zhao242/ShanYangProxyApps/main/Tz/$download_name"
    log "正在下载 $download_name"
    manager_fetch_file "$download_metadata" "$download_api" ||
        fail "无法从 GitHub 读取 $download_name 的校验信息"
    download_expected=$(sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$download_metadata" | sed -n '1p')
    case "$download_expected" in
        ????????????????????????????????????????) ;;
        *) fail "GitHub 返回的文件 SHA 无效" ;;
    esac
    manager_fetch_file "$SOURCE_BINARY" "$download_raw" ||
        fail "无法从 GitHub 下载 $download_name"
    [ -s "$SOURCE_BINARY" ] || fail "下载的 Agent 文件为空"
    download_size=$(wc -c < "$SOURCE_BINARY" | tr -d '[:space:]')
    case "$download_size" in ''|*[!0-9]*) fail "下载文件长度无效" ;; esac
    download_actual=$(
        { printf 'blob %s\000' "$download_size"; cat "$SOURCE_BINARY"; } |
            sha1sum | awk '{print $1}'
    ) || fail "无法校验下载文件"
    [ "$download_actual" = "$download_expected" ] ||
        fail "GitHub 文件 SHA 不匹配，已拒绝安装"
    chmod 0700 "$SOURCE_BINARY"
    log "下载校验通过，安装后清理临时原文件"
}

manager_download_cleanup() {
    [ -n "${MANAGER_DOWNLOAD_DIR:-}" ] || return 0
    case "$MANAGER_DOWNLOAD_DIR" in
        */komari-agent-download.*) ;;
        *) return 1 ;;
    esac
    rm -f -- "$MANAGER_DOWNLOAD_DIR/agent" "$MANAGER_DOWNLOAD_DIR/metadata.json" || return 1
    rmdir -- "$MANAGER_DOWNLOAD_DIR" || return 1
    MANAGER_DOWNLOAD_DIR=""
}

manager_backup_fail() {
    printf '%s\n' "[komari-agent] 备份失败：$*" >&2
    exit 1
}

manager_backup_discard() {
    case "${MANAGER_PENDING_BACKUP:-}" in
        "${MANAGER_BACKUP_ROOT:-}"/.pending.*)
            [ ! -L "$MANAGER_PENDING_BACKUP" ] || return 1
            rm -rf -- "$MANAGER_PENDING_BACKUP"
            ;;
    esac
    return 0
}

manager_backup_begin() {
    case "$SERVICE_NAME" in
        ''|[!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.@-]*) manager_backup_fail "服务名无效" ;;
    esac
    MANAGER_BACKUP_ROOT="/var/backups/komari-agent/$SERVICE_NAME"
    for backup_path in /var/backups/komari-agent "$MANAGER_BACKUP_ROOT" "$MANAGER_BACKUP_ROOT/latest"; do
        [ ! -L "$backup_path" ] || manager_backup_fail "备份路径不能是符号链接：$backup_path"
    done
    mkdir -p "$MANAGER_BACKUP_ROOT" || manager_backup_fail "无法创建备份目录"
    chmod 0700 /var/backups/komari-agent "$MANAGER_BACKUP_ROOT"
    MANAGER_PENDING_BACKUP=$(mktemp -d "$MANAGER_BACKUP_ROOT/.pending.XXXXXX") || manager_backup_fail "无法创建临时备份"
    BACKUP_DIR=$MANAGER_PENDING_BACKUP
    printf 'operation=%s\ncreated=%s\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S')" > "$BACKUP_DIR/backup-info"
}

manager_backup_publish() {
    # Publish a complete snapshot before deleting any older backup.
    backup_previous="$MANAGER_BACKUP_ROOT/.previous-$$"
    [ ! -e "$backup_previous" ] && [ ! -L "$backup_previous" ] || manager_backup_fail "备份暂存路径被占用"
    if [ -e "$MANAGER_BACKUP_ROOT/latest" ]; then
        [ -d "$MANAGER_BACKUP_ROOT/latest" ] || manager_backup_fail "latest 不是目录"
        mv "$MANAGER_BACKUP_ROOT/latest" "$backup_previous" || manager_backup_fail "无法轮换旧备份"
    fi
    if ! mv "$BACKUP_DIR" "$MANAGER_BACKUP_ROOT/latest"; then
        if [ -d "$backup_previous" ]; then
            mv "$backup_previous" "$MANAGER_BACKUP_ROOT/latest" || true
        fi
        manager_backup_fail "无法保存本次备份"
    fi
    MANAGER_PENDING_BACKUP=""
    BACKUP_DIR="$MANAGER_BACKUP_ROOT/latest"
    for backup_old in "$MANAGER_BACKUP_ROOT"/.previous-* "$MANAGER_BACKUP_ROOT"/.pending.*; do
        [ -d "$backup_old" ] && [ ! -L "$backup_old" ] || continue
        rm -rf -- "$backup_old" || manager_backup_fail "无法删除旧备份：$backup_old"
    done

    # Migrate backups produced by the former standalone scripts.
    legacy_agent_dir=$1
    case "$legacy_agent_dir" in
        /*)
            case "$legacy_agent_dir" in
                /|*/../*|*/..|*/./*|*/.) ;;
                *)
                    for backup_old in "$legacy_agent_dir"/.custom-agent-backup-*; do
                        [ -d "$backup_old" ] && [ ! -L "$backup_old" ] || continue
                        [ -f "$backup_old/agent" ] && [ -f "$backup_old/service" ] || continue
                        rm -rf -- "$backup_old" || manager_backup_fail "无法删除旧备份：$backup_old"
                    done
                    ;;
            esac
            ;;
    esac
    for backup_old in "$2"/.config.backup.*; do
        [ -f "$backup_old" ] && [ ! -L "$backup_old" ] || continue
        rm -f -- "$backup_old" || manager_backup_fail "无法删除旧配置备份：$backup_old"
    done
    printf '%s\n' "[komari-agent] 已保留最新备份：$BACKUP_DIR"
}

manager_detect_agent_dir() {
    if [ -n "${KOMARI_INSTALL_DIR:-}" ]; then
        printf '%s\n' "$KOMARI_INSTALL_DIR"
        return
    fi
    if [ "$INIT_SYSTEM" = systemd ]; then
        backup_command=$(systemctl cat "$SERVICE_UNIT" 2>/dev/null |
            sed -n 's/^[[:space:]]*ExecStart=//p' | sed -n '1p')
        backup_command=${backup_command#-}
    else
        backup_command=$(sed -n 's/^command=//p' "/etc/init.d/$SERVICE_NAME" | sed -n '1p')
    fi
    case "$backup_command" in
        \"*) backup_command=${backup_command#\"}; backup_command=${backup_command%%\"*} ;;
        *) backup_command=${backup_command%% *} ;;
    esac
    case "$backup_command" in
        /*) dirname "$backup_command" ;;
        *) printf '%s\n' /opt/komari ;;
    esac
}

manager_install() (
set -eu

SERVICE_NAME="${KOMARI_SERVICE_NAME:-komari-agent}"
SERVICE_UNIT="${SERVICE_NAME}.service"
SERVICE_USER="komari-agent"
INSTALL_DIR="${KOMARI_INSTALL_DIR:-/opt/komari}"
AGENT_PATH="${INSTALL_DIR}/agent"
CONFIG_DIR="/etc/komari-agent"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_DIR="/var/lib/komari-agent"
SYSCTL_FILE="/etc/sysctl.d/99-komari-agent-ping.conf"

SOURCE_BINARY=""
MANAGER_DOWNLOAD_DIR=""
PANEL_URL=""
TOKEN_FILE=""
NODE_TOKEN=""
MONTH_ROTATE=""
INIT_SYSTEM=""
SERVICE_FILE=""
SERVICE_GROUP=""
NEW_AGENT=""
NEW_CONFIG=""
NEW_SERVICE=""

ECHO_DISABLED=0
INSTALL_STARTED=0
INSTALL_COMMITTED=0
CREATED_USER=0
CREATED_GROUP=0
PING_RANGE_CHANGED=0
ORIGINAL_PING_MIN=""
ORIGINAL_PING_MAX=""
CURRENT_STEP="preflight checks"

log() {
    printf '%s\n' "[komari-agent] $*"
}

warn() {
    printf '%s\n' "[komari-agent] WARNING: $*" >&2
}

step() {
    CURRENT_STEP=$1
    log "step: $CURRENT_STEP"
}

fail() {
    printf '%s\n' "[komari-agent] ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: komari-agent-manager-linux.sh --worker install [options]

Installs the packaged Komari Agent on a new Debian, Ubuntu, or Alpine server.
Run it as root; the matching Agent is downloaded from GitHub.

Options:
  --endpoint URL             panel URL; prompted when omitted
  --token-file FILE          read the node token from the first line of FILE;
                             prompted without echo when omitted
  --month-rotate DAY         traffic reset day, 0-31 (default: 0)
  --service-name NAME        service name (default: komari-agent)
  --install-dir DIRECTORY    binary directory (default: /opt/komari)
  -h, --help                 show this help

KOMARI_SERVICE_NAME and KOMARI_INSTALL_DIR provide the same two defaults.
Use menu option 1 to replace an existing Komari Agent service.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --endpoint)
            [ "$#" -ge 2 ] || fail "--endpoint requires a value"
            PANEL_URL=$2
            shift 2
            ;;
        --token-file)
            [ "$#" -ge 2 ] || fail "--token-file requires a value"
            TOKEN_FILE=$2
            shift 2
            ;;
        --month-rotate)
            [ "$#" -ge 2 ] || fail "--month-rotate requires a value"
            MONTH_ROTATE=$2
            shift 2
            ;;
        --service-name)
            [ "$#" -ge 2 ] || fail "--service-name requires a value"
            SERVICE_NAME=$2
            SERVICE_UNIT="${SERVICE_NAME}.service"
            shift 2
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || fail "--install-dir requires a value"
            INSTALL_DIR=$2
            AGENT_PATH="${INSTALL_DIR}/agent"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

rollback() {
    [ "$INSTALL_STARTED" -eq 1 ] || return 0

    set +e
    warn "installation failed; rolling back files created by this run"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "/run/${SERVICE_NAME}.pid"
    fi

    if [ "$PING_RANGE_CHANGED" -eq 1 ] && \
        [ -n "$ORIGINAL_PING_MIN" ] && [ -n "$ORIGINAL_PING_MAX" ]; then
        sysctl -w "net.ipv4.ping_group_range=${ORIGINAL_PING_MIN} ${ORIGINAL_PING_MAX}" \
            >/dev/null 2>&1 || true
    fi
    rm -f "$SYSCTL_FILE"

    [ -z "$NEW_SERVICE" ] || rm -f "$NEW_SERVICE"
    [ -z "$NEW_CONFIG" ] || rm -f "$NEW_CONFIG"
    [ -z "$NEW_AGENT" ] || rm -f "$NEW_AGENT"

    rm -rf "$CONFIG_DIR" "$STATE_DIR" "$INSTALL_DIR"

    if [ "$CREATED_USER" -eq 1 ] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then
            userdel "$SERVICE_USER" >/dev/null 2>&1 || true
        elif command -v deluser >/dev/null 2>&1; then
            deluser "$SERVICE_USER" >/dev/null 2>&1 || true
        fi
    fi
    if [ "$CREATED_GROUP" -eq 1 ] && grep -q "^${SERVICE_USER}:" /etc/group 2>/dev/null; then
        if command -v groupdel >/dev/null 2>&1; then
            groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
        elif command -v delgroup >/dev/null 2>&1; then
            delgroup "$SERVICE_USER" >/dev/null 2>&1 || true
        fi
    fi
}

cleanup() {
    status=$?
    trap - 0
    if ! manager_download_cleanup; then
        warn "无法清理 Agent 下载临时目录：$MANAGER_DOWNLOAD_DIR"
        status=1
    fi
    manager_backup_discard || status=1
    if [ "$ECHO_DISABLED" -eq 1 ]; then
        stty echo 2>/dev/null || true
        printf '\n'
    fi
    NODE_TOKEN=""
    if [ "$INSTALL_COMMITTED" -ne 1 ]; then
        if [ "$status" -ne 0 ]; then
            warn "failed during: $CURRENT_STEP (exit status $status)"
        fi
        rollback
    fi
    exit "$status"
}

trap cleanup 0
trap 'exit 1' 1 2 15

[ "$(id -u)" -eq 0 ] || fail "run this script as root"

case "$SERVICE_NAME" in
    ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9_.@-]*)
        fail "invalid service name: $SERVICE_NAME"
        ;;
esac

case "$INSTALL_DIR" in
    /*) ;;
    *) fail "install directory must be an absolute path" ;;
esac
case "$INSTALL_DIR" in
    /|*/|/*/../*|/*/..|/*/./*|/*/.|*//*|/bin|/sbin|/usr|/etc|/var|/opt|/home|/root|/tmp|/dev|/proc|/sys|/run|/usr/local|/usr/local/bin|/var/lib|/var/local|/srv|/mnt)
        fail "install directory is too broad or contains ambiguous path segments"
        ;;
esac
case "$INSTALL_DIR" in
    *[!A-Za-z0-9_./-]*)
        fail "install directory contains unsupported characters"
        ;;
esac

for command_name in id uname sed grep tr awk dirname cp mv chmod chown mkdir rm sleep; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command was not found: $command_name"
done

[ -r /etc/os-release ] || fail "cannot identify this Linux distribution"
OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | sed -n '1p' | tr -d '"')
case "$OS_ID" in
    debian|ubuntu)
        command -v systemctl >/dev/null 2>&1 || fail "systemd is required on Debian/Ubuntu"
        systemctl list-units >/dev/null 2>&1 || fail "systemd is not running"
        INIT_SYSTEM="systemd"
        SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT}"
        ;;
    alpine)
        command -v rc-service >/dev/null 2>&1 || fail "OpenRC rc-service was not found"
        command -v rc-update >/dev/null 2>&1 || fail "OpenRC rc-update was not found"
        command -v rc-status >/dev/null 2>&1 || fail "OpenRC rc-status was not found"
        command -v supervise-daemon >/dev/null 2>&1 || fail "OpenRC supervise-daemon was not found"
        [ -x /sbin/openrc-run ] || fail "/sbin/openrc-run was not found"
        [ -d /run/openrc ] || fail "OpenRC is installed but is not running (/run/openrc is missing)"
        INIT_SYSTEM="openrc"
        SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
        ;;
    *)
        fail "unsupported distribution: ${OS_ID:-unknown}; expected Debian, Ubuntu, or Alpine"
        ;;
esac

case "$(uname -m)" in
    x86_64)
        AGENT_ARCH="amd64"
        ;;
    aarch64|arm64)
        AGENT_ARCH="arm64"
        ;;
    *)
        fail "unsupported architecture: $(uname -m)"
        ;;
esac

if [ "$INIT_SYSTEM" = "systemd" ] && systemctl cat "$SERVICE_UNIT" >/dev/null 2>&1; then
    fail "$SERVICE_UNIT already exists; return to menu option 1 to replace it"
fi
if [ -e "$SERVICE_FILE" ] || [ -L "$SERVICE_FILE" ]; then
    fail "$SERVICE_FILE already exists; return to menu option 1 to replace it"
fi
for owned_path in "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR" "$SYSCTL_FILE"; do
    if [ -e "$owned_path" ] || [ -L "$owned_path" ]; then
        fail "$owned_path already exists; move/remove it or use the replacement script"
    fi
done
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    fail "user $SERVICE_USER already exists; refusing to reuse an unrelated account"
fi
if grep -q "^${SERVICE_USER}:" /etc/group 2>/dev/null; then
    fail "group $SERVICE_USER already exists; refusing to reuse an unrelated group"
fi

if [ -z "$PANEL_URL" ]; then
    [ -t 0 ] || fail "--endpoint is required without an interactive terminal"
    printf '面板地址（例如 https://monitor.example.com；q 返回菜单）：'
    IFS= read -r PANEL_URL
fi
PANEL_URL=$(printf '%s' "$PANEL_URL" | tr -d '\r')
manager_check_cancel "$PANEL_URL"
while [ "${PANEL_URL%/}" != "$PANEL_URL" ]; do
    PANEL_URL=${PANEL_URL%/}
done
case "$PANEL_URL" in
    http://?*|https://?*) ;;
    *) fail "panel URL must start with http:// or https:// and include a host" ;;
esac
case "$PANEL_URL" in
    *[[:space:]]*) fail "panel URL must not contain whitespace" ;;
esac

if [ -n "$TOKEN_FILE" ]; then
    [ -r "$TOKEN_FILE" ] || fail "token file is not readable: $TOKEN_FILE"
    NODE_TOKEN=$(sed -n '1p' "$TOKEN_FILE" | tr -d '\r')
else
    [ -t 0 ] || fail "--token-file is required without an interactive terminal"
    command -v stty >/dev/null 2>&1 || fail "stty is required for hidden token input"
    printf '节点 Token（不回显；q 返回菜单）：'
    ECHO_DISABLED=1
    stty -echo
    IFS= read -r NODE_TOKEN
    stty echo
    ECHO_DISABLED=0
    printf '\n'
    NODE_TOKEN=$(printf '%s' "$NODE_TOKEN" | tr -d '\r')
manager_check_cancel "$NODE_TOKEN"
fi
[ -n "$NODE_TOKEN" ] || fail "node token cannot be empty"
if printf '%s' "$NODE_TOKEN" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "node token contains control characters"
fi

if [ -z "$MONTH_ROTATE" ]; then
    if [ -t 0 ]; then
        printf '流量重置日 [0]（0=关闭，1-31；q 返回菜单）：'
        IFS= read -r MONTH_ROTATE
    fi
    [ -n "$MONTH_ROTATE" ] || MONTH_ROTATE=0
fi
MONTH_ROTATE=$(printf '%s' "$MONTH_ROTATE" | tr -d '\r')
manager_check_cancel "$MONTH_ROTATE"
case "$MONTH_ROTATE" in
    0|[1-9]|[12][0-9]|3[01]) ;;
    *) fail "traffic reset day must be 0-31" ;;
esac

manager_download_agent "$AGENT_ARCH"

log "distribution: $OS_ID"
log "init system: $INIT_SYSTEM"
log "architecture: $AGENT_ARCH"
log "panel: $PANEL_URL"
log "token: received (hidden)"
log "installing to: $AGENT_PATH"

INSTALL_STARTED=1

step "creating the restricted service account"
if command -v groupadd >/dev/null 2>&1; then
    groupadd --system "$SERVICE_USER"
elif command -v addgroup >/dev/null 2>&1; then
    addgroup -S "$SERVICE_USER"
else
    fail "groupadd/addgroup was not found"
fi
CREATED_GROUP=1

if [ -x /usr/sbin/nologin ]; then
    NOLOGIN_SHELL=/usr/sbin/nologin
elif [ -x /sbin/nologin ]; then
    NOLOGIN_SHELL=/sbin/nologin
else
    NOLOGIN_SHELL=/bin/false
fi

if command -v useradd >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_USER" --home-dir "$STATE_DIR" \
        --no-create-home --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
elif command -v adduser >/dev/null 2>&1; then
    adduser -S -D -H -h "$STATE_DIR" -s "$NOLOGIN_SHELL" \
        -G "$SERVICE_USER" "$SERVICE_USER"
else
    fail "useradd/adduser was not found"
fi
CREATED_USER=1
SERVICE_GROUP=$(id -gn "$SERVICE_USER")

step "creating protected installation directories"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"
chown root:root "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"
chown "root:$SERVICE_GROUP" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR"
chmod 0750 "$STATE_DIR"

step "installing and validating the Agent binary"
NEW_AGENT="${INSTALL_DIR}/.agent.install.$$"
cp "$SOURCE_BINARY" "$NEW_AGENT"
chown root:root "$NEW_AGENT"
chmod 0755 "$NEW_AGENT"
"$NEW_AGENT" --help >/dev/null 2>&1 || fail "packaged Agent cannot run on this host"
mv "$NEW_AGENT" "$AGENT_PATH"

json_escape() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ENDPOINT_JSON=$(printf '%s' "$PANEL_URL" | json_escape)
TOKEN_JSON=$(printf '%s' "$NODE_TOKEN" | json_escape)
NEW_CONFIG="${CONFIG_DIR}/.config.install.$$"
step "writing the Agent configuration"
umask 0077
{
    printf '{\n'
    printf '  "endpoint": "%s",\n' "$ENDPOINT_JSON"
    printf '  "token": "%s",\n' "$TOKEN_JSON"
    printf '  "interval": 3,\n'
    printf '  "info_report_interval": 5,\n'
    printf '  "month_rotate": %s\n' "$MONTH_ROTATE"
    printf '}\n'
} > "$NEW_CONFIG"
chown "root:$SERVICE_GROUP" "$NEW_CONFIG"
chmod 0640 "$NEW_CONFIG"
mv "$NEW_CONFIG" "$CONFIG_FILE"
NODE_TOKEN=""
TOKEN_JSON=""

step "creating the $INIT_SYSTEM service"
if [ "$INIT_SYSTEM" = "systemd" ]; then
    mkdir -p /etc/systemd/system
    NEW_SERVICE="/etc/systemd/system/.${SERVICE_UNIT}.install.$$"
    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=Komari Custom Monitoring Agent'
        printf '%s\n' 'Wants=network-online.target'
        printf '%s\n' 'After=network-online.target'
        printf '\n'
        printf '%s\n' '[Service]'
        printf '%s\n' 'Type=simple'
        printf 'ExecStart="%s" --config "%s"\n' "$AGENT_PATH" "$CONFIG_FILE"
        printf 'User=%s\n' "$SERVICE_USER"
        printf 'Group=%s\n' "$SERVICE_GROUP"
        printf 'WorkingDirectory=%s\n' "$STATE_DIR"
        printf '%s\n' 'Restart=always'
        printf '%s\n' 'RestartSec=5'
        printf '%s\n' 'UMask=0077'
        printf '%s\n' 'NoNewPrivileges=true'
        printf '%s\n' 'CapabilityBoundingSet='
        printf '%s\n' 'AmbientCapabilities='
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$NEW_SERVICE"
    chmod 0644 "$NEW_SERVICE"
    mv "$NEW_SERVICE" "$SERVICE_FILE"
else
    NEW_SERVICE="/etc/init.d/.${SERVICE_NAME}.install.$$"
    {
        printf '%s\n' '#!/sbin/openrc-run'
        printf '\n'
        printf '%s\n' 'name="Komari Custom Monitoring Agent"'
        printf '%s\n' 'description="Komari monitoring agent"'
        printf 'command="%s"\n' "$AGENT_PATH"
        printf 'command_args="--config %s"\n' "$CONFIG_FILE"
        printf 'command_user="%s:%s"\n' "$SERVICE_USER" "$SERVICE_GROUP"
        printf 'directory="%s"\n' "$STATE_DIR"
        printf 'pidfile="/run/%s.pid"\n' "$SERVICE_NAME"
        printf '%s\n' 'retry="SIGTERM/30"'
        printf '%s\n' 'supervisor=supervise-daemon'
        printf '\n'
        printf '%s\n' 'depend() {'
        printf '%s\n' '    need net'
        printf '%s\n' '    after network'
        printf '%s\n' '}'
    } > "$NEW_SERVICE"
    chmod 0755 "$NEW_SERVICE"
    mv "$NEW_SERVICE" "$SERVICE_FILE"
fi

step "configuring unprivileged Ping access"
if [ -r /proc/sys/net/ipv4/ping_group_range ] && command -v sysctl >/dev/null 2>&1; then
    PING_VALUES_VALID=1
    if ! AGENT_GID=$(id -g "$SERVICE_USER" 2>/dev/null); then
        PING_VALUES_VALID=0
    fi
    if ! PING_RANGE=$(sed -n '1p' /proc/sys/net/ipv4/ping_group_range 2>/dev/null); then
        PING_VALUES_VALID=0
        PING_RANGE=""
    fi
    ORIGINAL_PING_MIN=$(printf '%s\n' "$PING_RANGE" | awk '{print $1}')
    ORIGINAL_PING_MAX=$(printf '%s\n' "$PING_RANGE" | awk '{print $2}')
    for ping_value in "$AGENT_GID" "$ORIGINAL_PING_MIN" "$ORIGINAL_PING_MAX"; do
        case "$ping_value" in
            ''|*[!0-9]*) PING_VALUES_VALID=0 ;;
        esac
    done

    if [ "$PING_VALUES_VALID" -ne 1 ]; then
        warn "could not read net.ipv4.ping_group_range; continuing without Ping permission changes"
    else
        NEW_MIN=$ORIGINAL_PING_MIN
        NEW_MAX=$ORIGINAL_PING_MAX
        if [ "$AGENT_GID" -lt "$NEW_MIN" ]; then
            NEW_MIN=$AGENT_GID
        fi
        if [ "$AGENT_GID" -gt "$NEW_MAX" ]; then
            NEW_MAX=$AGENT_GID
        fi
        if [ "$NEW_MIN" != "$ORIGINAL_PING_MIN" ] || [ "$NEW_MAX" != "$ORIGINAL_PING_MAX" ]; then
            if sysctl -w "net.ipv4.ping_group_range=${NEW_MIN} ${NEW_MAX}" >/dev/null 2>&1; then
                PING_RANGE_CHANGED=1
                if ! mkdir -p /etc/sysctl.d 2>/dev/null || \
                    ! printf 'net.ipv4.ping_group_range = %s %s\n' "$NEW_MIN" "$NEW_MAX" > "$SYSCTL_FILE" || \
                    ! chmod 0644 "$SYSCTL_FILE"; then
                    warn "Ping permission was changed for this boot but could not be persisted"
                    rm -f "$SYSCTL_FILE" 2>/dev/null || true
                fi
            else
                warn "could not expand net.ipv4.ping_group_range; Ping tasks may fail"
            fi
        fi
    fi
fi

step "enabling and starting the Agent service"
if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl daemon-reload || fail "systemd could not reload unit files"
    systemctl enable "$SERVICE_UNIT" >/dev/null || fail "systemd could not enable $SERVICE_UNIT"
    systemctl start "$SERVICE_UNIT" || fail "systemd could not start $SERVICE_UNIT"
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_UNIT"; then
        systemctl status "$SERVICE_UNIT" --no-pager --lines=20 >&2 || true
        fail "$SERVICE_UNIT did not remain active"
    fi
else
    rc-update add "$SERVICE_NAME" default >/dev/null || fail "OpenRC could not enable $SERVICE_NAME"
    rc-service "$SERVICE_NAME" start || fail "OpenRC could not start $SERVICE_NAME"
    sleep 3
    if ! rc-service "$SERVICE_NAME" status; then
        fail "$SERVICE_NAME did not remain active under OpenRC"
    fi
fi

INSTALL_COMMITTED=1
CURRENT_STEP="complete"
log "installation completed"
log "binary: $AGENT_PATH"
log "configuration: $CONFIG_FILE"
log "state directory: $STATE_DIR"
log "traffic reset day: $MONTH_ROTATE"
log "check the Komari panel to confirm that the node is online"
)

manager_replace() (
set -eu

SERVICE_NAME="${KOMARI_SERVICE_NAME:-komari-agent}"
SERVICE_UNIT="${SERVICE_NAME}.service"
SERVICE_USER="komari-agent"
STATE_DIR="/var/lib/komari-agent"
CONFIG_DIR="/etc/komari-agent"
CONFIG_FILE="${CONFIG_DIR}/config.json"

NEW_AGENT=""
NEW_CONTROL=""
NEW_CONFIG=""
STATE_TEMP=""
SOURCE_BINARY=""
MANAGER_DOWNLOAD_DIR=""
STATE_MIGRATED=0
ECHO_DISABLED=0

log() {
    printf '%s\n' "[komari-agent] $*"
}

fail() {
    printf '%s\n' "[komari-agent] ERROR: $*" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - 0
    set +e
    if [ "$ECHO_DISABLED" -eq 1 ]; then
        stty echo 2>/dev/null || true
        printf '\n'
    fi
    [ -z "$NEW_AGENT" ] || rm -f "$NEW_AGENT"
    [ -z "$NEW_CONTROL" ] || rm -f "$NEW_CONTROL"
    [ -z "$NEW_CONFIG" ] || rm -f "$NEW_CONFIG"
    [ -z "$STATE_TEMP" ] || rm -f "$STATE_TEMP"
    if ! manager_download_cleanup; then
        log "无法清理 Agent 下载临时目录：$MANAGER_DOWNLOAD_DIR"
        status=1
    fi
    manager_backup_discard || status=1
    exit "$status"
}

trap cleanup 0
trap 'exit 1' 1 2 15

json_escape() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

[ "$(id -u)" -eq 0 ] || fail "run this script as root"
[ -t 0 ] || fail "an interactive terminal is required to enter endpoint and token"

INIT_SYSTEM=""
CONTROL_FILE=""

# Alpine should prefer its native OpenRC service even if systemctl happens to exist.
if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1 && \
    [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    INIT_SYSTEM="openrc"
    CONTROL_FILE="/etc/init.d/${SERVICE_NAME}"
elif command -v systemctl >/dev/null 2>&1; then
    CONTROL_FILE=$(systemctl show -p FragmentPath --value "$SERVICE_UNIT" 2>/dev/null || true)
    if [ -n "$CONTROL_FILE" ] && [ -f "$CONTROL_FILE" ]; then
        INIT_SYSTEM="systemd"
    fi
fi

if [ -z "$INIT_SYSTEM" ] && command -v rc-service >/dev/null 2>&1 && \
    [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    INIT_SYSTEM="openrc"
    CONTROL_FILE="/etc/init.d/${SERVICE_NAME}"
fi

[ -n "$INIT_SYSTEM" ] || fail "could not find the installed $SERVICE_NAME service"

case "$(uname -m)" in
    x86_64)
        AGENT_ARCH="amd64"
        ;;
    aarch64|arm64)
        AGENT_ARCH="arm64"
        ;;
    *)
        fail "unsupported architecture: $(uname -m)"
        ;;
esac

if [ "$INIT_SYSTEM" = "openrc" ]; then
    AGENT_PATH=$(sed -n 's/^command=//p' "$CONTROL_FILE" | sed -n '1p')
    AGENT_PATH=${AGENT_PATH#\"}
    AGENT_PATH=${AGENT_PATH%\"}
else
    EXEC_START=$(sed -n 's/^[[:space:]]*ExecStart=//p' "$CONTROL_FILE" | sed -n '1p')
    [ -n "$EXEC_START" ] || fail "systemd service has no ExecStart"
    EXEC_START=${EXEC_START#-}
    case "$EXEC_START" in
        \"*)
            AGENT_PATH=${EXEC_START#\"}
            AGENT_PATH=${AGENT_PATH%%\"*}
            ;;
        *)
            AGENT_PATH=${EXEC_START%% *}
            ;;
    esac
fi

[ -n "$AGENT_PATH" ] || fail "cannot read the agent path from $CONTROL_FILE"
case "$AGENT_PATH" in
    /*) ;;
    *) fail "service command is not an absolute path: $AGENT_PATH" ;;
esac
[ -f "$AGENT_PATH" ] || fail "installed official agent not found: $AGENT_PATH"

if [ "$INIT_SYSTEM" = "openrc" ]; then
    ORIGINAL_ARGS=$(sed -n 's/^command_args=//p' "$CONTROL_FILE" | sed -n '1p')
else
    ORIGINAL_ARGS=$EXEC_START
fi

MONTH_ROTATE_DEFAULT=""
if [ -f "$CONFIG_FILE" ]; then
    MONTH_ROTATE_DEFAULT=$(sed -n \
        's/.*"month_rotate"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$CONFIG_FILE" | sed -n '1p')
fi
if [ -z "$MONTH_ROTATE_DEFAULT" ]; then
    MONTH_ROTATE_DEFAULT=$(printf '%s\n' "$ORIGINAL_ARGS" | sed -n \
        's/.*--month-rotate[=[:space:]]\{1,\}\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
fi
[ -n "$MONTH_ROTATE_DEFAULT" ] || MONTH_ROTATE_DEFAULT=0
case "$MONTH_ROTATE_DEFAULT" in
    0|[1-9]|[12][0-9]|3[01]) ;;
    *) MONTH_ROTATE_DEFAULT=0 ;;
esac

# The official agent default is five minutes. Preserve an explicitly
# configured value when one exists, while always writing the value to the new
# JSON so the compact agent does not depend on a binary default.
INFO_REPORT_INTERVAL=""
if [ -f "$CONFIG_FILE" ]; then
    INFO_REPORT_INTERVAL=$(sed -n \
        's/.*"info_report_interval"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$CONFIG_FILE" | sed -n '1p')
fi
if [ -z "$INFO_REPORT_INTERVAL" ]; then
    INFO_REPORT_INTERVAL=$(printf '%s\n' "$ORIGINAL_ARGS" | sed -n \
        's/.*--info-report-interval[=[:space:]]\{1,\}\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
fi
case "$INFO_REPORT_INTERVAL" in
    ''|*[!0-9]*) INFO_REPORT_INTERVAL=5 ;;
    *) [ "$INFO_REPORT_INTERVAL" -gt 0 ] 2>/dev/null || INFO_REPORT_INTERVAL=5 ;;
esac

# Preserve a custom public IPv4 address when the official installation set it
# in JSON or as a command-line argument.  If it was supplied through
# AGENT_CUSTOM_IPV4 in the service environment, leave the JSON field absent so
# the preserved environment variable remains authoritative.
CUSTOM_IPV4=""
if [ -f "$CONFIG_FILE" ]; then
    CUSTOM_IPV4=$(sed -n \
        's/.*"custom_ipv4"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$CONFIG_FILE" | sed -n '1p')
fi
if [ -z "$CUSTOM_IPV4" ]; then
    CUSTOM_IPV4=$(printf '%s\n' "$ORIGINAL_ARGS" | sed -n \
        -e 's/.*--custom-ipv4[=]"\([^"]*\)".*/\1/p' \
        -e 's/.*--custom-ipv4[=]\([^[:space:]]*\).*/\1/p' \
        -e 's/.*--custom-ipv4[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' \
        -e 's/.*--custom-ipv4[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | sed -n '1p')
fi

log "现有服务：$SERVICE_NAME"
log "服务文件：$CONTROL_FILE"
log "现有配置：$CONFIG_FILE"
log "替换 / 更新会重新生成启动参数，请输入新的面板地址和 Token；输入 q 返回菜单。"

printf '面板地址（例如 https://monitor.example.com；q 返回菜单）：'
IFS= read -r PANEL_URL
PANEL_URL=$(printf '%s' "$PANEL_URL" | tr -d '\r')
manager_check_cancel "$PANEL_URL"
while [ "${PANEL_URL%/}" != "$PANEL_URL" ]; do
    PANEL_URL=${PANEL_URL%/}
done
case "$PANEL_URL" in
    http://*|https://*) ;;
    *) fail "panel URL must start with http:// or https://" ;;
esac

printf '节点 Token（不回显；q 返回菜单）：'
ECHO_DISABLED=1
stty -echo
IFS= read -r NODE_TOKEN
stty echo
ECHO_DISABLED=0
printf '\n'
NODE_TOKEN=$(printf '%s' "$NODE_TOKEN" | tr -d '\r')
manager_check_cancel "$NODE_TOKEN"
[ -n "$NODE_TOKEN" ] || fail "node token cannot be empty"

log "new endpoint: $PANEL_URL"
log "new token: received (hidden)"

printf '流量重置日 [%s]（0=关闭，1-31；q 返回菜单）：' "$MONTH_ROTATE_DEFAULT"
IFS= read -r MONTH_ROTATE
MONTH_ROTATE=$(printf '%s' "$MONTH_ROTATE" | tr -d '\r')
manager_check_cancel "$MONTH_ROTATE"
[ -n "$MONTH_ROTATE" ] || MONTH_ROTATE=$MONTH_ROTATE_DEFAULT
case "$MONTH_ROTATE" in
    0|[1-9]|[12][0-9]|3[01]) ;;
    *) fail "traffic reset day must be 0-31" ;;
esac

manager_download_agent "$AGENT_ARCH"

if ! grep -q "^${SERVICE_USER}:" /etc/group; then
    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system "$SERVICE_USER"
    else
        addgroup -S "$SERVICE_USER"
    fi
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if [ -x /usr/sbin/nologin ]; then
        NOLOGIN_SHELL=/usr/sbin/nologin
    elif [ -x /sbin/nologin ]; then
        NOLOGIN_SHELL=/sbin/nologin
    else
        NOLOGIN_SHELL=/bin/false
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_USER" --home-dir "$STATE_DIR" \
            --no-create-home --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
    else
        adduser -S -D -H -h "$STATE_DIR" -s "$NOLOGIN_SHELL" \
            -G "$SERVICE_USER" "$SERVICE_USER"
    fi
fi

SERVICE_GROUP=$(id -gn "$SERVICE_USER")
mkdir -p "$STATE_DIR" "$CONFIG_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR"
chmod 0750 "$STATE_DIR"
chown "root:$SERVICE_GROUP" "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"

AGENT_DIR=$(dirname "$AGENT_PATH")
LEGACY_STATE_FILE="${AGENT_DIR}/net_static.json"
manager_backup_begin replace
cp -p "$AGENT_PATH" "$BACKUP_DIR/agent"
cp -p "$CONTROL_FILE" "$BACKUP_DIR/service"
if [ -f "$LEGACY_STATE_FILE" ]; then
    cp -p "$LEGACY_STATE_FILE" "$BACKUP_DIR/net_static.json"
fi
if [ -f "$CONFIG_FILE" ]; then
    cp -p "$CONFIG_FILE" "$BACKUP_DIR/config.json"
    : > "$BACKUP_DIR/config-existed"
fi

SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT}"
DROPIN_FILE="/etc/systemd/system/${SERVICE_UNIT}.d/90-komari-custom-agent.conf"
if [ "$INIT_SYSTEM" = "systemd" ]; then
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        cp -p "$SYSTEMD_SERVICE_FILE" "$BACKUP_DIR/systemd-service"
        : > "$BACKUP_DIR/systemd-service-existed"
    fi
    if [ -f "$DROPIN_FILE" ]; then
        cp -p "$DROPIN_FILE" "$BACKUP_DIR/dropin"
        : > "$BACKUP_DIR/dropin-existed"
    fi
fi

manager_backup_publish "$AGENT_DIR" "$CONFIG_DIR"

NEW_AGENT="${AGENT_DIR}/.agent.custom.$$"
NEW_CONTROL="${BACKUP_DIR}/.service.custom.$$"
NEW_CONFIG="${CONFIG_DIR}/.config.custom.$$"

cp "$SOURCE_BINARY" "$NEW_AGENT"
chown root:root "$NEW_AGENT"
chmod 0755 "$NEW_AGENT"
"$NEW_AGENT" --help >/dev/null 2>&1 || fail "custom binary cannot run on this host"

ENDPOINT_JSON=$(printf '%s' "$PANEL_URL" | json_escape)
TOKEN_JSON=$(printf '%s' "$NODE_TOKEN" | json_escape)
CUSTOM_IPV4_JSON=$(printf '%s' "$CUSTOM_IPV4" | json_escape)
umask 0077
{
    printf '{\n'
    printf '  "endpoint": "%s",\n' "$ENDPOINT_JSON"
    printf '  "token": "%s",\n' "$TOKEN_JSON"
    printf '  "interval": 3,\n'
    printf '  "info_report_interval": %s,\n' "$INFO_REPORT_INTERVAL"
    if [ -n "$CUSTOM_IPV4" ]; then
        printf '  "custom_ipv4": "%s",\n' "$CUSTOM_IPV4_JSON"
    fi
    printf '  "month_rotate": %s\n' "$MONTH_ROTATE"
    printf '}\n'
} > "$NEW_CONFIG"
chown "root:$SERVICE_GROUP" "$NEW_CONFIG"
chmod 0640 "$NEW_CONFIG"
NODE_TOKEN=""
TOKEN_JSON=""
CUSTOM_IPV4_JSON=""

if [ "$INIT_SYSTEM" = "openrc" ]; then
    cp -p "$CONTROL_FILE" "$NEW_CONTROL"
    sed -i 's|^command_args=.*|command_args="--config /etc/komari-agent/config.json"|' "$NEW_CONTROL"
    sed -i 's/^command_user=.*/command_user="komari-agent"/' "$NEW_CONTROL"
    sed -i 's|^directory=.*|directory="/var/lib/komari-agent"|' "$NEW_CONTROL"
    if grep -q '^required_files=' "$NEW_CONTROL"; then
        sed -i 's|^required_files=.*|required_files="/etc/komari-agent/config.json"|' "$NEW_CONTROL"
    else
        printf '\nrequired_files="/etc/komari-agent/config.json"\n' >> "$NEW_CONTROL"
    fi
    chmod 0700 "$NEW_CONTROL"
else
    SYSTEMD_AGENT_PATH=$(printf '%s' "$AGENT_PATH" | sed -e 's/%/%%/g' -e 's/"/\\"/g')
    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=Komari Custom Monitoring Agent'
        printf '%s\n' 'Wants=network-online.target'
        printf '%s\n' 'After=network-online.target'
        printf '\n'
        printf '%s\n' '[Service]'
        printf '%s\n' 'Type=simple'
        printf 'ExecStart="%s" --config "%s"\n' "$SYSTEMD_AGENT_PATH" "$CONFIG_FILE"
        printf 'User=%s\n' "$SERVICE_USER"
        printf 'Group=%s\n' "$SERVICE_GROUP"
        # Preserve the effective service environment. In particular this
        # keeps proxy variables and EnvironmentFile entries from both the
        # main unit and any systemd drop-ins.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl cat "$SERVICE_UNIT" 2>/dev/null | sed -n \
                -e '/^[[:space:]]*Environment=/p' \
                -e '/^[[:space:]]*EnvironmentFile=/p'
        else
            sed -n \
                -e '/^[[:space:]]*Environment=/p' \
                -e '/^[[:space:]]*EnvironmentFile=/p' \
                "$CONTROL_FILE"
        fi
        printf 'WorkingDirectory=%s\n' "$STATE_DIR"
        printf '%s\n' 'Restart=always'
        printf '%s\n' 'RestartSec=5'
        printf '%s\n' 'UMask=0077'
        printf '%s\n' 'NoNewPrivileges=true'
        printf '%s\n' 'CapabilityBoundingSet='
        printf '%s\n' 'AmbientCapabilities='
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$NEW_CONTROL"
    chmod 0644 "$NEW_CONTROL"
fi

service_is_running() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl is-active --quiet "$SERVICE_UNIT"
    else
        rc-service "$SERVICE_NAME" status >/dev/null 2>&1
    fi
}

service_stop() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop "$SERVICE_UNIT"
    else
        rc-service "$SERVICE_NAME" stop
    fi
}

service_start() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl start "$SERVICE_UNIT"
    else
        rc-service "$SERVICE_NAME" start
    fi
}

WAS_RUNNING=0
if service_is_running; then
    WAS_RUNNING=1
    service_stop
fi

rollback() {
    log "new service failed; restoring the previous binary and configuration"
    service_stop >/dev/null 2>&1 || true
    cp -p "$BACKUP_DIR/agent" "$AGENT_PATH"
    if [ -f "$BACKUP_DIR/config-existed" ]; then
        cp -p "$BACKUP_DIR/config.json" "$CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi

    if [ "$INIT_SYSTEM" = "openrc" ]; then
        cp -p "$BACKUP_DIR/service" "$CONTROL_FILE"
    else
        if [ -f "$BACKUP_DIR/systemd-service-existed" ]; then
            cp -p "$BACKUP_DIR/systemd-service" "$SYSTEMD_SERVICE_FILE"
        else
            rm -f "$SYSTEMD_SERVICE_FILE"
        fi
        if [ -f "$BACKUP_DIR/dropin-existed" ]; then
            mkdir -p "$(dirname "$DROPIN_FILE")"
            cp -p "$BACKUP_DIR/dropin" "$DROPIN_FILE"
        else
            rm -f "$DROPIN_FILE"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [ "$WAS_RUNNING" -eq 1 ]; then
        service_start >/dev/null 2>&1 || true
    fi
    if [ "$STATE_MIGRATED" -eq 1 ]; then
        rm -f "$STATE_DIR/net_static.json"
    fi
    fail "replacement was rolled back; backup: $BACKUP_DIR"
}

if [ -f "$LEGACY_STATE_FILE" ] && [ ! -f "$STATE_DIR/net_static.json" ]; then
    STATE_TEMP="$STATE_DIR/.net_static.json.custom.$$"
    if ! cp -p "$LEGACY_STATE_FILE" "$STATE_TEMP"; then
        rollback
    fi
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_TEMP"
    chmod 0600 "$STATE_TEMP"
    if ! mv "$STATE_TEMP" "$STATE_DIR/net_static.json"; then
        rollback
    fi
    STATE_TEMP=""
    STATE_MIGRATED=1
    log "migrated existing traffic state to $STATE_DIR/net_static.json"
fi

if ! mv "$NEW_AGENT" "$AGENT_PATH" || ! mv "$NEW_CONFIG" "$CONFIG_FILE"; then
    rollback
fi

if [ "$INIT_SYSTEM" = "openrc" ]; then
    if ! mv "$NEW_CONTROL" "$CONTROL_FILE"; then
        rollback
    fi
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
else
    if ! mkdir -p /etc/systemd/system || \
        ! mv "$NEW_CONTROL" "$SYSTEMD_SERVICE_FILE" || \
        ! rm -f "$DROPIN_FILE"; then
        rollback
    fi
    if ! systemctl daemon-reload; then
        rollback
    fi
    systemctl enable "$SERVICE_UNIT" >/dev/null 2>&1 || true
fi

if ! service_start; then
    rollback
fi
sleep 2
if ! service_is_running; then
    rollback
fi

# Allow monitoring-only ICMP through Linux unprivileged ping sockets.
if [ -r /proc/sys/net/ipv4/ping_group_range ]; then
    AGENT_GID=$(id -g "$SERVICE_USER")
    read -r PING_MIN PING_MAX < /proc/sys/net/ipv4/ping_group_range
    NEW_MIN=$PING_MIN
    NEW_MAX=$PING_MAX
    if [ "$AGENT_GID" -lt "$NEW_MIN" ]; then
        NEW_MIN=$AGENT_GID
    fi
    if [ "$AGENT_GID" -gt "$NEW_MAX" ]; then
        NEW_MAX=$AGENT_GID
    fi
    if [ "$NEW_MIN" != "$PING_MIN" ] || [ "$NEW_MAX" != "$PING_MAX" ]; then
        if sysctl -w "net.ipv4.ping_group_range=${NEW_MIN} ${NEW_MAX}" >/dev/null 2>&1; then
            if mkdir -p /etc/sysctl.d && \
                printf 'net.ipv4.ping_group_range = %s %s\n' "$NEW_MIN" "$NEW_MAX" \
                    > /etc/sysctl.d/99-komari-agent-ping.conf; then
                log "unprivileged ICMP group range was configured"
            else
                log "WARNING: ICMP range is active but could not be persisted"
            fi
        else
            log "WARNING: could not expand net.ipv4.ping_group_range; Ping tasks may fail"
        fi
    fi
fi

log "replacement completed"
log "init system: $INIT_SYSTEM"
log "architecture: $AGENT_ARCH"
log "binary: $AGENT_PATH"
log "configuration: $CONFIG_FILE"
log "traffic reset day: $MONTH_ROTATE"
log "old runtime arguments were replaced, not inherited"
log "backup: $BACKUP_DIR"
log "check the Komari panel to confirm that the node is online"
)

manager_modify() (
set -eu
SERVICE_NAME="${KOMARI_SERVICE_NAME:-komari-agent}"
SERVICE_UNIT="${SERVICE_NAME}.service"
CONFIG_FILE="${KOMARI_CONFIG_FILE:-/etc/komari-agent/config.json}"
CONFIG_DIR=${CONFIG_FILE%/*}
INIT_SYSTEM=""
EDIT_DIR=""
CONFIG_CHANGED=0
ECHO_DISABLED=0

log() { printf '%s\n' "[komari-agent] $*"; }
fail() { printf '%s\n' "[komari-agent] 错误：$*" >&2; exit 1; }
service_restart() {
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl restart "$SERVICE_UNIT"
    else
        rc-service "$SERVICE_NAME" restart
    fi
}
service_is_running() {
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl is-active --quiet "$SERVICE_UNIT"
    else
        rc-service "$SERVICE_NAME" status >/dev/null 2>&1
    fi
}
cleanup() {
    status=$?
    manager_backup_discard
    trap - 0 1 2 15
    if [ "$ECHO_DISABLED" -eq 1 ]; then
        stty echo 2>/dev/null || true
        printf '\n'
    fi
    if [ "$CONFIG_CHANGED" -eq 1 ]; then
        log "服务未正常启动，正在恢复原配置……"
        if mv -f "$EDIT_DIR/original.json" "$CONFIG_FILE"; then
            if service_restart && service_is_running; then
                log "原配置已恢复，服务已重新启动。"
            else
                log "原配置已恢复，但服务启动失败，请检查 $SERVICE_NAME。"
                status=1
            fi
        else
            log "自动恢复失败，原配置备份位于 $EDIT_DIR/original.json。"
            status=1
        fi
    fi
    if [ -n "$EDIT_DIR" ]; then
        rm -f "$EDIT_DIR/draft.json" "$EDIT_DIR/next.json"
        # Keep the backup when restoring it failed.
        if [ "$CONFIG_CHANGED" -eq 0 ]; then
            rm -f "$EDIT_DIR/original.json"
        fi
        rmdir "$EDIT_DIR" 2>/dev/null || true
    fi
    exit "$status"
}

# The Agent schema is a flat JSON object of scalar values. Parse the complete
# object before editing; reject duplicate keys or malformed JSON without
# emitting its contents. Preserve every unselected field, including unknown
# scalar fields. New values arrive on stdin, never in argv (especially Token).
config_json() {
    awk -v mode="$1" -v target="$2" '
        FILENAME == "-" { replacement = $0; next }
        { data = data $0 "\n" }
        function ws() {
            while (substr(data, pos, 1) ~ /^[ \t\r\n]$/) pos++
        }
        function string_value( start, c, e, h) {
            start = pos
            if (substr(data, pos++, 1) != "\"") exit 1
            while (pos <= length(data)) {
                c = substr(data, pos++, 1)
                if (c == "\"") return substr(data, start, pos - start)
                if (c ~ /[[:cntrl:]]/) exit 1
                if (c == "\\") {
                    e = substr(data, pos++, 1)
                    if (e == "u") {
                        h = substr(data, pos, 4)
                        if (length(h) != 4 || h ~ /[^0-9a-fA-F]/) exit 1
                        pos += 4
                    } else if (e !~ /^["\\\/bfnrt]$/) exit 1
                }
            }
            exit 1
        }
        function scalar( rest, value) {
            if (substr(data, pos, 1) == "\"") return string_value()
            rest = substr(data, pos)
            if (!match(rest, /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)/)) exit 1
            value = substr(rest, 1, RLENGTH)
            pos += RLENGTH
            return value
        }
        END {
            pos = 1
            ws()
            if (substr(data, pos++, 1) != "{") exit 1
            ws()
            if (substr(data, pos, 1) != "}") {
                while (1) {
                    raw_key = string_value()
                    key = substr(raw_key, 2, length(raw_key) - 2)
                    if (index(key, "\\") || key in values) exit 1
                    ws()
                    if (substr(data, pos++, 1) != ":") exit 1
                    ws()
                    values[key] = scalar()
                    keys[++count] = key
                    ws()
                    separator = substr(data, pos, 1)
                    if (separator == "}") break
                    if (separator != ",") exit 1
                    pos++
                    ws()
                }
            }
            pos++
            ws()
            if (pos <= length(data)) exit 1
            if (mode == "validate") exit 0
            if (mode == "get") {
                print (target in values) ? values[target] : "__MISSING__"
                exit 0
            }
            if (mode != "set" || replacement == "") exit 1
            if (!(target in values)) keys[++count] = target
            values[target] = replacement
            print "{"
            for (i = 1; i <= count; i++)
                printf "  \"%s\": %s%s\n", keys[i], values[keys[i]], (i < count ? "," : "")
            print "}"
        }
    ' "$3" ${4:+"$4"}
}

read_value() {
    if ! IFS= read -r FIELD_VALUE; then exit 10; fi
    FIELD_VALUE=$(printf '%s' "$FIELD_VALUE" | tr -d '\r')
    manager_check_cancel "$FIELD_VALUE"
}

normalize_endpoint() {
    case "$FIELD_VALUE" in
        http://*|https://*) ;;
        *://*|*/*) return 1 ;;
        *)
            old_endpoint=${CURRENT_VALUE#\"}
            old_endpoint=${old_endpoint%\"}
            case "$old_endpoint" in
                http://?*|https://?*) ;;
                *) return 1 ;;
            esac
            case "$old_endpoint" in *\\*) return 1 ;; esac
            old_scheme=${old_endpoint%%://*}
            old_rest=${old_endpoint#*://}
            old_authority=${old_rest%%/*}
            old_path=${old_rest#"$old_authority"}
            old_port=""
            case "$old_authority" in
                \[*\]:*) old_port=${old_authority##*:} ;;
                \[*\]) ;;
                *:*) old_port=${old_authority##*:} ;;
            esac
            case "$FIELD_VALUE" in
                *:*) ;;
                *) FIELD_VALUE="${FIELD_VALUE}${old_port:+:$old_port}" ;;
            esac
            FIELD_VALUE="$old_scheme://$FIELD_VALUE$old_path"
            ;;
    esac
    case "$FIELD_VALUE" in
        *[[:space:]]*|*\"*|*\\*|*\?*|*\#*|*@*) return 1 ;;
    esac
    rest=${FIELD_VALUE#*://}
    authority=${rest%%/*}
    [ -n "$authority" ] || return 1
    # Let Agent startup validate addresses further; malformed configuration
    # is restored automatically if the service cannot start.
    return 0
}

normalize_number() {
    # The reset day must be an integer from 0 to 31.
    value=$(printf '%s\n' "$FIELD_VALUE" | awk '
        {
            if ($0 !~ /^[0-9]+$/ || $0 + 0 > 31) exit 1
            printf "%.0f", $0 + 0
        }
    ') || return 1
    JSON_VALUE=$value
}

[ "$(id -u)" -eq 0 ] || fail "请以 root 运行"
case "$CONFIG_FILE" in /*) ;; *) fail "配置路径必须是绝对路径" ;; esac
[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || fail "找不到常规配置文件：$CONFIG_FILE"
config_json validate '' "$CONFIG_FILE" || fail "配置必须是有效的 JSON 对象，每个字段使用字符串、数字、布尔值或 null"

if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1 &&
    [ -f "/etc/init.d/$SERVICE_NAME" ]; then
    INIT_SYSTEM=openrc
elif command -v systemctl >/dev/null 2>&1 &&
    systemctl cat "$SERVICE_UNIT" >/dev/null 2>&1; then
    INIT_SYSTEM=systemd
elif command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/$SERVICE_NAME" ]; then
    INIT_SYSTEM=openrc
else
    fail "找不到 $SERVICE_NAME 服务"
fi
if [ "$INIT_SYSTEM" = systemd ]; then
    systemctl cat "$SERVICE_UNIT" | grep -Fq -- "$CONFIG_FILE" || fail "服务未使用配置文件 $CONFIG_FILE"
else
    grep -Fq -- "$CONFIG_FILE" "/etc/init.d/$SERVICE_NAME" || fail "服务未使用配置文件 $CONFIG_FILE"
fi

umask 0077
trap cleanup 0
trap 'exit 1' 1 2 15
EDIT_DIR=$(mktemp -d "$CONFIG_DIR/.config-edit.XXXXXX") || fail "无法创建配置草稿"
cp -p "$CONFIG_FILE" "$EDIT_DIR/original.json"
cp -p "$CONFIG_FILE" "$EDIT_DIR/draft.json"
DRAFT="$EDIT_DIR/draft.json"

while :; do
    cat <<'EOF'

========== 修改配置（子菜单） ==========
  1. 面板域名 / 地址
  2. 节点 Token
  3. 流量重置日
  4. 自定义 IPv4
  s. 保存全部修改并重启服务
  q. 放弃未保存修改，返回主菜单

安装 / 更新、卸载位于主菜单，输入 q 返回后选择。
EOF
    printf '请选择：'
    read_value
    case "$FIELD_VALUE" in
        s|S)
            if cmp -s "$DRAFT" "$EDIT_DIR/original.json"; then
                log "没有配置变更。"
                exit 0
            fi
            cmp -s "$CONFIG_FILE" "$EDIT_DIR/original.json" || fail "配置已被其他程序修改，请重新进入修改菜单"
            config_json validate '' "$DRAFT" || fail "配置草稿格式错误"
            manager_backup_begin modify
            cp -p "$EDIT_DIR/original.json" "$BACKUP_DIR/config.json"
            manager_backup_publish "$(manager_detect_agent_dir)" "$CONFIG_DIR"
            CONFIG_CHANGED=1
            mv -f "$DRAFT" "$CONFIG_FILE"
            log "配置已保存，正在重启 $SERVICE_NAME……"
            service_restart || fail "服务重启失败"
            sleep 2
            service_is_running || fail "服务未正常运行"
            CONFIG_CHANGED=0
            log "配置修改已生效。"
            exit 0
            ;;
        1) FIELD=endpoint; TYPE=string; LABEL="面板域名 / 地址"; HINT="新域名或完整 http(s) 地址；只填域名会保留原协议、端口和路径" ;;
        2) FIELD=token; TYPE=string; LABEL="节点 Token"; HINT="输入新 Token，内容不回显" ;;
        3) FIELD=month_rotate; TYPE=number; LABEL="流量重置日"; HINT="0-31；0 关闭，1-31 为每月重置日" ;;
        4) FIELD=custom_ipv4; TYPE=string; LABEL="自定义 IPv4"; HINT="IPv4 地址；输入 - 清空" ;;
        *) log "请输入 1、2、3、4、s 或 q。"; continue ;;
    esac
    CURRENT_VALUE=$(config_json get "$FIELD" "$DRAFT") || fail "无法读取配置草稿"
    printf '\n%s\n' "$LABEL"
    if [ "$FIELD" = token ]; then
        if [ "$CURRENT_VALUE" = __MISSING__ ] || [ "$CURRENT_VALUE" = '""' ]; then
            printf '当前值：未设置\n'
        else
            printf '当前值：已设置（隐藏）\n'
        fi
    elif [ "$CURRENT_VALUE" = __MISSING__ ]; then
        printf '当前值：未设置，使用 Agent 默认值\n'
    else
        printf '当前值：%s\n' "$CURRENT_VALUE"
    fi
    printf '%s\n' "$HINT"
    printf '新值（回车保留，q 放弃修改并返回主菜单）：'
    if [ "$FIELD" = token ] && [ -t 0 ]; then
        ECHO_DISABLED=1
        stty -echo
    fi
    if ! IFS= read -r FIELD_VALUE; then exit 10; fi
    if [ "$ECHO_DISABLED" -eq 1 ]; then
        stty echo
        ECHO_DISABLED=0
        printf '\n'
    fi
    FIELD_VALUE=$(printf '%s' "$FIELD_VALUE" | tr -d '\r')
    manager_check_cancel "$FIELD_VALUE"
    [ -n "$FIELD_VALUE" ] || continue
    if printf '%s' "$FIELD_VALUE" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        log "输入不能包含控制字符。"; continue
    fi

    if [ "$TYPE" = string ]; then
        if [ "$FIELD_VALUE" = '-' ]; then
            case "$FIELD" in
                endpoint|token) log "面板地址和 Token 不能为空。"; continue ;;
                *) FIELD_VALUE="" ;;
            esac
        fi
        case "$FIELD" in
            endpoint)
                if ! normalize_endpoint; then log "面板地址无效，请输入域名或完整 http(s) 地址。"; continue; fi ;;
        esac
        JSON_VALUE=$(printf '%s' "$FIELD_VALUE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        JSON_VALUE="\"$JSON_VALUE\""
    else
        if ! normalize_number; then log "数值无效：$HINT。"; continue; fi
    fi

    if [ "$JSON_VALUE" = "$CURRENT_VALUE" ]; then
        log "该项未变化。"
        continue
    fi
    cp -p "$DRAFT" "$EDIT_DIR/next.json"
    if ! printf '%s\n' "$JSON_VALUE" | config_json set "$FIELD" "$DRAFT" - > "$EDIT_DIR/next.json"; then
        fail "无法更新配置草稿"
    fi
    mv -f "$EDIT_DIR/next.json" "$DRAFT"
    FIELD_VALUE=""
    JSON_VALUE=""
    CURRENT_VALUE=""
    log "$LABEL 已暂存；按 s 保存，按 q 放弃并回到主菜单。"
done
)


manager_uninstall() (
set -eu

SERVICE_NAME="${KOMARI_SERVICE_NAME:-komari-agent}"
SERVICE_UNIT="${SERVICE_NAME}.service"
SERVICE_USER="komari-agent"
CONFIG_DIR="/etc/komari-agent"
STATE_DIR="/var/lib/komari-agent"
SYSCTL_FILE="/etc/sysctl.d/99-komari-agent-ping.conf"
INSTALL_DIR="${KOMARI_INSTALL_DIR:-}"
AGENT_PATH=""
ASSUME_YES=0

log() {
    printf '%s\n' "[komari-agent] $*"
}

warn() {
    printf '%s\n' "[komari-agent] WARNING: $*" >&2
}

fail() {
    printf '%s\n' "[komari-agent] ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: komari-agent-manager-linux.sh --worker uninstall [options]

Options:
  -y, --yes                 do not ask for confirmation
  --service-name NAME       service name (default: komari-agent)
  --install-dir DIRECTORY   installation directory (auto-detected by default)
  -h, --help                show this help

The same values can be supplied with KOMARI_SERVICE_NAME and
KOMARI_INSTALL_DIR environment variables.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        --service-name)
            [ "$#" -ge 2 ] || fail "--service-name requires a value"
            SERVICE_NAME=$2
            SERVICE_UNIT="${SERVICE_NAME}.service"
            shift 2
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || fail "--install-dir requires a value"
            INSTALL_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fail "run this script as root"

case "$SERVICE_NAME" in
    ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9_.@-]*)
        fail "invalid service name: $SERVICE_NAME"
        ;;
esac

read_systemd_agent_path() {
    unit_file="/etc/systemd/system/${SERVICE_UNIT}"
    [ -f "$unit_file" ] || return 1

    exec_start=$(sed -n 's/^[[:space:]]*ExecStart=//p' "$unit_file" | sed -n '1p')
    [ -n "$exec_start" ] || return 1
    exec_start=${exec_start#-}
    case "$exec_start" in
        \"*)
            detected_path=${exec_start#\"}
            detected_path=${detected_path%%\"*}
            ;;
        *)
            detected_path=${exec_start%% *}
            ;;
    esac
    [ -n "$detected_path" ] || return 1
    printf '%s\n' "$detected_path"
}

read_openrc_agent_path() {
    init_file="/etc/init.d/${SERVICE_NAME}"
    [ -f "$init_file" ] || return 1

    detected_path=$(sed -n 's/^command=//p' "$init_file" | sed -n '1p')
    detected_path=${detected_path#\"}
    detected_path=${detected_path%\"}
    [ -n "$detected_path" ] || return 1
    printf '%s\n' "$detected_path"
}

if [ -z "$INSTALL_DIR" ]; then
    AGENT_PATH=$(read_systemd_agent_path 2>/dev/null || true)
    if [ -z "$AGENT_PATH" ]; then
        AGENT_PATH=$(read_openrc_agent_path 2>/dev/null || true)
    fi
    if [ -n "$AGENT_PATH" ]; then
        INSTALL_DIR=$(dirname "$AGENT_PATH")
    else
        INSTALL_DIR="/opt/komari"
        AGENT_PATH="${INSTALL_DIR}/agent"
    fi
else
    AGENT_PATH="${INSTALL_DIR}/agent"
fi

safe_install_dir=1
case "$INSTALL_DIR" in
    /*) ;;
    *) safe_install_dir=0 ;;
esac
case "$INSTALL_DIR" in
    /|*/|/*/../*|/*/..|/*/./*|/*/.|*//*|/bin|/sbin|/usr|/etc|/var|/opt|/home|/root|/tmp|/dev|/proc|/sys|/run|/usr/local|/usr/local/bin|/var/lib|/var/local|/srv|/mnt)
        safe_install_dir=0
        ;;
esac

BACKUP_ROOT="/var/backups/komari-agent/$SERVICE_NAME"
log "the following Komari Agent data will be permanently removed:"
log "  service: ${SERVICE_UNIT} (systemd/OpenRC definitions and enablement)"
if [ "$safe_install_dir" -eq 1 ]; then
    log "  install directory: ${INSTALL_DIR}"
else
    warn "installation directory is too broad or ambiguous to remove recursively: ${INSTALL_DIR}"
    log "  agent binary only: ${AGENT_PATH}"
fi
log "  configuration: ${CONFIG_DIR}"
log "  state: ${STATE_DIR}"
log "  account: ${SERVICE_USER} (user and group)"
log "  sysctl file: ${SYSCTL_FILE}"
log "  backup directory: $BACKUP_ROOT"

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || fail "interactive confirmation is unavailable; rerun with --yes"
    printf '输入服务名 "%s" 确认卸载（q 返回菜单）：' "$SERVICE_NAME"
    IFS= read -r answer
    answer=$(printf '%s' "$answer" | tr -d '\r')
    manager_check_cancel "$answer"
    [ "$answer" = "$SERVICE_NAME" ] || fail "confirmation did not match; nothing was removed"
fi

# Stop and disable every supported service form before deleting files.
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true
fi

if command -v rc-service >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
fi
if command -v rc-update >/dev/null 2>&1; then
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
fi

# A dedicated service account must not have processes left when it is removed.
if id -u "$SERVICE_USER" >/dev/null 2>&1 && \
    command -v pgrep >/dev/null 2>&1 && command -v pkill >/dev/null 2>&1; then
    if pgrep -u "$SERVICE_USER" >/dev/null 2>&1; then
        pkill -TERM -u "$SERVICE_USER" >/dev/null 2>&1 || true
        sleep 1
        if pgrep -u "$SERVICE_USER" >/dev/null 2>&1; then
            pkill -KILL -u "$SERVICE_USER" >/dev/null 2>&1 || true
        fi
    fi
fi

rm -f "/etc/systemd/system/${SERVICE_UNIT}"
rm -rf "/etc/systemd/system/${SERVICE_UNIT}.d"
if [ -d /etc/systemd/system ]; then
    find /etc/systemd/system -type l -name "$SERVICE_UNIT" -exec rm -f {} \; 2>/dev/null || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
fi

rm -f "/etc/init.d/${SERVICE_NAME}"
if [ -d /etc/runlevels ]; then
    find /etc/runlevels -type l -name "$SERVICE_NAME" -exec rm -f {} \; 2>/dev/null || true
fi
rm -f "/run/${SERVICE_NAME}.pid"

rm -rf "$CONFIG_DIR" "$STATE_DIR"
rm -f "$SYSCTL_FILE"
rm -rf "$BACKUP_ROOT"
rmdir /var/backups/komari-agent 2>/dev/null || true

if [ "$safe_install_dir" -eq 1 ]; then
    rm -rf "$INSTALL_DIR"
else
    rm -f "$AGENT_PATH"
fi

rm -f "/var/mail/${SERVICE_USER}" "/var/spool/mail/${SERVICE_USER}"

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then
        userdel "$SERVICE_USER" || warn "could not remove user ${SERVICE_USER}"
    elif command -v deluser >/dev/null 2>&1; then
        deluser "$SERVICE_USER" || warn "could not remove user ${SERVICE_USER}"
    else
        warn "no user deletion command was found"
    fi
fi

if grep -q "^${SERVICE_USER}:" /etc/group 2>/dev/null; then
    if command -v groupdel >/dev/null 2>&1; then
        groupdel "$SERVICE_USER" || warn "could not remove group ${SERVICE_USER}"
    elif command -v delgroup >/dev/null 2>&1; then
        delgroup "$SERVICE_USER" || warn "could not remove group ${SERVICE_USER}"
    else
        warn "no group deletion command was found"
    fi
fi

leftovers=0
for leftover in \
    "/etc/systemd/system/${SERVICE_UNIT}" \
    "/etc/systemd/system/${SERVICE_UNIT}.d" \
    "/etc/init.d/${SERVICE_NAME}" \
    "$CONFIG_DIR" \
    "$STATE_DIR" \
    "$SYSCTL_FILE" \
    "$BACKUP_ROOT"
do
    if [ -e "$leftover" ] || [ -L "$leftover" ]; then
        warn "leftover path: $leftover"
        leftovers=1
    fi
done
if [ "$safe_install_dir" -eq 1 ] && { [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; }; then
    warn "leftover path: $INSTALL_DIR"
    leftovers=1
fi
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    warn "leftover user: $SERVICE_USER"
    leftovers=1
fi
if grep -q "^${SERVICE_USER}:" /etc/group 2>/dev/null; then
    warn "leftover group: $SERVICE_USER"
    leftovers=1
fi

if [ "$leftovers" -ne 0 ]; then
    fail "uninstall finished with leftovers; review the warnings above"
fi

log "Komari Agent files, service, state, configuration, user, and group were removed"
log "the live ping_group_range value may remain widened until the next reboot"
log "delete the node in the Komari panel separately if it should disappear there too"
)

# Internal worker entry points share this file but never delete the manager.
# A new shell is intentional: calling set -e functions inside "if" disables
# errexit in POSIX shells and would otherwise break installation rollback.
if [ "${1:-}" = --worker ]; then
    shift
    worker_action=${1:-}
    [ "$#" -eq 0 ] || shift
    case "$worker_action" in
        install) manager_install "$@" ;;
        replace) manager_replace "$@" ;;
        modify) manager_modify "$@" ;;
        uninstall) manager_uninstall "$@" ;;
        *) printf '%s\n' '未知操作。' >&2; exit 1 ;;
    esac
    exit $?
fi

set -u

manager_log() {
    printf '%s\n' "[komari-agent] $*"
}

manager_fail() {
    printf '%s\n' "[komari-agent] 错误：$*" >&2
    exit 1
}

manager_usage() {
    cat <<'EOF'
用法：sh komari-agent-manager-linux.sh

  1. 安装（已有服务时替换 / 更新）
  2. 修改探针配置
  3. 卸载
  0. 退出并删除本脚本

安装 / 更新会从 GitHub 的 Tz 目录自动下载当前架构的 Agent。
只需上传本管理脚本；下载的原文件在操作结束时自动删除。

各输入处输入 q 可放弃本次操作并返回主菜单。
操作完成或失败后返回菜单；选择 0、输入结束或按 Ctrl+C 时，
自动删除本次上传的管理脚本和运行时临时文件。

KOMARI_SERVICE_NAME 指定服务名，默认 komari-agent。
KOMARI_INSTALL_DIR 指定首次安装目录；卸载时默认从服务中识别。
KOMARI_CONFIG_FILE 可指定修改配置时使用的配置文件。
EOF
}

case "${1:-}" in
    -h|--help) manager_usage; exit 0 ;;
    '') ;;
    *) manager_usage >&2; exit 1 ;;
esac
[ "$#" -eq 0 ] || manager_fail "请直接运行脚本进入菜单"
[ "$(id -u)" -eq 0 ] || manager_fail "请以 root 运行"

MANAGER_SERVICE=${KOMARI_SERVICE_NAME:-komari-agent}
case "$MANAGER_SERVICE" in
    ''|[!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.@-]*) manager_fail "无效的服务名：$MANAGER_SERVICE" ;;
esac

for manager_command in sh dirname mktemp cp chmod mkdir rm rmdir grep tr cmp; do
    command -v "$manager_command" >/dev/null 2>&1 || manager_fail "缺少命令：$manager_command"
done

MANAGER_SELF=$0
if [ ! -f "$MANAGER_SELF" ]; then
    MANAGER_SELF=$(command -v "$MANAGER_SELF" 2>/dev/null || true)
fi
[ -n "$MANAGER_SELF" ] && [ -f "$MANAGER_SELF" ] || manager_fail "无法定位当前脚本"
MANAGER_DIRECTORY=$(CDPATH= cd -P "$(dirname "$MANAGER_SELF")" && pwd) || manager_fail "无法读取脚本目录"
MANAGER_SELF="$MANAGER_DIRECTORY/${MANAGER_SELF##*/}"
grep -Fxq '# KOMARI_AGENT_MANAGER=1' "$MANAGER_SELF" || manager_fail "当前文件不是管理脚本，请使用 sh 运行脚本文件"

# Keep a private runtime copy so uninstall also works when the uploaded manager
# happens to be inside the installation directory being removed.
umask 0077
MANAGER_RUNTIME=$(mktemp -d "${TMPDIR:-/tmp}/komari-agent-manager.XXXXXX") || manager_fail "无法创建临时目录"
if ! cp "$MANAGER_SELF" "$MANAGER_RUNTIME/manager.sh" || ! chmod 0600 "$MANAGER_RUNTIME/manager.sh"; then
    rm -f -- "$MANAGER_RUNTIME/manager.sh"
    rmdir -- "$MANAGER_RUNTIME" 2>/dev/null || true
    manager_fail "无法准备运行文件"
fi
MANAGER_LOCK="/run/komari-agent-manager-$MANAGER_SERVICE.lock"
MANAGER_OWNS_LOCK=0

manager_cleanup() {
    manager_status=$?
    trap - 0 1 2 15
    if [ "$MANAGER_OWNS_LOCK" -eq 1 ]; then
        rm -f -- "$MANAGER_LOCK/pid" || manager_status=1
        rmdir -- "$MANAGER_LOCK" 2>/dev/null || manager_status=1
    fi
    if [ -e "$MANAGER_SELF" ] || [ -L "$MANAGER_SELF" ]; then
        # Do not delete a different file that was put at this path during use.
        if cmp -s "$MANAGER_SELF" "$MANAGER_RUNTIME/manager.sh"; then
            if rm -f -- "$MANAGER_SELF"; then
                manager_log "已退出，脚本已自动删除：$MANAGER_SELF"
            else
                printf '%s\n' "[komari-agent] 无法删除脚本，请手动删除：$MANAGER_SELF" >&2
                manager_status=1
            fi
        else
            printf '%s\n' "[komari-agent] 脚本文件在运行期间已改变，已保留：$MANAGER_SELF" >&2
            manager_status=1
        fi
    fi
    rm -f -- "$MANAGER_RUNTIME/manager.sh" || manager_status=1
    rmdir -- "$MANAGER_RUNTIME" 2>/dev/null || manager_status=1
    exit "$manager_status"
}

trap manager_cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

# Serialize maintenance and backup rotation for this service. A stale lock
# from a terminated process is removed using only its known PID file.
if ! mkdir "$MANAGER_LOCK" 2>/dev/null; then
    if [ ! -L "$MANAGER_LOCK" ] && [ -f "$MANAGER_LOCK/pid" ]; then
        manager_old_pid=$(cat "$MANAGER_LOCK/pid")
        case "$manager_old_pid" in
            ''|*[!0-9]*) ;;
            *)
                if ! kill -0 "$manager_old_pid" 2>/dev/null; then
                    rm -f -- "$MANAGER_LOCK/pid"
                    rmdir -- "$MANAGER_LOCK" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    mkdir "$MANAGER_LOCK" 2>/dev/null || manager_fail "已有管理脚本正在操作 $MANAGER_SERVICE，请先退出另一个菜单"
fi
MANAGER_OWNS_LOCK=1
printf '%s\n' "$$" > "$MANAGER_LOCK/pid" || manager_fail "无法记录运行状态"

manager_service_exists() {
    [ -f "/etc/init.d/$MANAGER_SERVICE" ] && return 0
    [ -f "/etc/systemd/system/$MANAGER_SERVICE.service" ] && return 0
    command -v systemctl >/dev/null 2>&1 &&
        systemctl cat "$MANAGER_SERVICE.service" >/dev/null 2>&1
}

manager_run() {
    if sh "$MANAGER_RUNTIME/manager.sh" --worker "$1"; then
        manager_log "操作完成，返回主菜单。"
    else
        manager_result=$?
        if [ "$manager_result" -eq 10 ]; then
            manager_log "已取消，返回主菜单。"
        else
            manager_log "操作未完成（退出码 $manager_result），可按提示处理后重试。"
        fi
    fi
}

manager_install_menu() {
    if manager_service_exists; then
        manager_log "检测到已有服务，将进入替换 / 更新流程，重新输入面板地址和 Token。"
        manager_run replace
    else
        manager_log "开始首次安装。"
        manager_run install
    fi
}

while :; do
    printf '\n%s\n' '========== Komari 探针管理（主菜单） =========='
    printf '服务名：%s\n' "$MANAGER_SERVICE"
    printf '%s\n' \
        '  1. 安装（已有服务时替换 / 更新）' \
        '  2. 修改探针配置' \
        '  3. 卸载' \
        '  0. 退出并删除本脚本'
    printf '请选择 [0-3]：'
    if ! IFS= read -r manager_choice; then
        printf '\n'
        exit 0
    fi
    manager_choice=$(printf '%s' "$manager_choice" | tr -d '\r')
    case "$manager_choice" in
        1) manager_install_menu ;;
        2) manager_run modify ;;
        3) manager_run uninstall ;;
        0) exit 0 ;;
        q|Q) continue ;;
        *) manager_log "请输入 0、1、2 或 3。" ;;
    esac
done
