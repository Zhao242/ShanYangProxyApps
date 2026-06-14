#!/usr/bin/env bash
set -o pipefail

CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="${CONFIG_DIR}/config.json"
DATA_DIR="/var/lib/sing-box"
SERVICE_NAME="sing-box"

OS_FAMILY=""
SERVICE_MANAGER=""

SS_PORT_DEFAULT="21958"
REALITY_PORT_DEFAULT="21959"
UUID_DEFAULT="4bd7d2f4-9f01-4596-b4d3-326d2f0b27e5"
NODE_NAME_DEFAULT="ShanYang"
SS_METHOD_DEFAULT="2022-blake3-aes-128-gcm"

info() { echo -e "${CYAN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
error() { echo -e "${RED}$*${NC}" >&2; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        error "当前不是 root，且系统未安装 sudo，请使用 root 运行此脚本"
        exit 1
    fi
}

detect_os() {
    local id="" id_like="" pretty_name=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
        pretty_name="${PRETTY_NAME:-}"
    fi

    local os_text="${id} ${id_like}"
    case "$os_text" in
        *alpine*)
            OS_FAMILY="alpine"
            ;;
        *debian*|*ubuntu*)
            OS_FAMILY="debian"
            ;;
        *)
            if command_exists apk; then
                OS_FAMILY="alpine"
            elif command_exists apt-get; then
                OS_FAMILY="debian"
            else
                error "暂不支持当前系统：${pretty_name:-unknown}"
                exit 1
            fi
            ;;
    esac
}

detect_service_manager() {
    if command_exists systemctl && [[ -d /run/systemd/system ]]; then
        SERVICE_MANAGER="systemd"
    elif command_exists rc-service && command_exists rc-update; then
        SERVICE_MANAGER="openrc"
    else
        SERVICE_MANAGER="none"
    fi
}

install_base_tools_debian() {
    run_as_root apt-get update -qq >/dev/null 2>&1
    run_as_root apt-get install -yq ca-certificates curl openssl >/dev/null 2>&1
}

install_base_tools_alpine() {
    run_as_root apk update >/dev/null
    run_as_root apk add --no-cache ca-certificates curl openssl shadow >/dev/null
}

install_sing_box_debian() {
    install_base_tools_debian

    info "添加 sing-box 官方 APT 仓库..."
    run_as_root mkdir -p /etc/apt/keyrings
    run_as_root curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    run_as_root chmod a+r /etc/apt/keyrings/sagernet.asc
    run_as_root tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    echo "正在更新包列表，请稍候..."
    run_as_root apt-get update -qq >/dev/null 2>&1

    echo "正在安装 sing-box 稳定版..."
    run_as_root apt-get install -yq sing-box >/dev/null 2>&1
}

install_sing_box_alpine() {
    install_base_tools_alpine

    info "使用 APK 安装 sing-box..."
    if run_as_root apk add --no-cache sing-box; then
        return
    fi

    warn "默认 Alpine 仓库未找到 sing-box，尝试 Alpine edge/testing 仓库..."
    run_as_root apk add --no-cache \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
        sing-box
}

install_sing_box() {
    if command_exists sing-box; then
        local current_version
        current_version="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
        echo "检测到已安装 sing-box，当前版本: ${current_version:-unknown}"
        read -rp "请选择操作 (1=升级到最新稳定版 / 2=跳过安装 / q=退出): " install_choice
        case "$install_choice" in
            1)
                ;;
            2)
                echo "跳过安装步骤"
                ;;
            q|Q)
                echo "已退出"
                exit 0
                ;;
            *)
                warn "输入无效，默认跳过安装步骤"
                ;;
        esac

        if [[ "${install_choice:-2}" != "1" ]]; then
            return
        fi
    fi

    case "$OS_FAMILY" in
        debian)
            install_sing_box_debian
            ;;
        alpine)
            install_sing_box_alpine
            ;;
        *)
            error "暂不支持当前系统：${OS_FAMILY}"
            exit 1
            ;;
    esac
}

ensure_sing_box_available() {
    if ! command_exists sing-box; then
        error "sing-box 不可用，请检查安装日志或网络配置"
        exit 1
    fi

    local version
    version="$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')"
    success "sing-box 可用，版本： ${version:-unknown}"
}

ensure_sing_box_user() {
    if id sing-box >/dev/null 2>&1; then
        return
    fi

    echo "正在创建 sing-box 系统用户..."

    if command_exists useradd; then
        local nologin="/usr/sbin/nologin"
        [[ -x "$nologin" ]] || nologin="/sbin/nologin"
        run_as_root useradd --system --no-create-home --user-group --shell "$nologin" sing-box
    elif command_exists adduser && command_exists addgroup; then
        run_as_root addgroup -S sing-box 2>/dev/null || true
        run_as_root adduser -S -D -H -h "$DATA_DIR" -s /sbin/nologin -G sing-box sing-box
    else
        error "未找到 useradd 或 adduser，无法创建 sing-box 用户"
        exit 1
    fi

    if ! id sing-box >/dev/null 2>&1; then
        error "sing-box 用户创建失败"
        exit 1
    fi
}

generate_ss_password() {
    if command_exists openssl; then
        openssl rand -base64 16
    else
        head -c 16 /dev/urandom | base64
    fi
}

generate_uuid() {
    if command_exists uuidgen; then
        uuidgen | tr 'A-Z' 'a-z'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        sing-box generate uuid
    fi
}

generate_short_id() {
    if command_exists openssl; then
        openssl rand -hex 8
    else
        head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

generate_reality_keypair() {
    local output
    output="$(sing-box generate reality-keypair 2>/dev/null || true)"
    reality_private_key="$(echo "$output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
    reality_public_key="$(echo "$output" | awk -F': ' '/PublicKey/ {print $2; exit}')"

    if [[ -z "$reality_private_key" || -z "$reality_public_key" ]]; then
        error "Reality 密钥对生成失败，请确认 sing-box 版本支持 'generate reality-keypair'"
        exit 1
    fi
}

read_required() {
    local prompt="$1"
    local value=""
    while [[ -z "$value" ]]; do
        read -rp "$prompt: " value
        [[ -n "$value" ]] || error "不能为空"
    done
    printf '%s' "$value"
}

collect_custom_config() {
    echo
    info "=== 自定义模式 ==="

    ss_port="$(read_required "请输入 Shadowsocks 端口")"
    ss_password="$(read_required "请输入 Shadowsocks 密钥 (${SS_METHOD_DEFAULT}，需 base64，16 字节)")"
    reality_port="$(read_required "请输入 Reality 端口")"
    uuid="$(read_required "请输入 Reality UUID")"
    reality_private_key="$(read_required "请输入 Reality private_key")"
    reality_short_id="$(read_required "请输入 Reality short_id")"
    reality_sni="$(read_required "请输入 Reality SNI 域名 (TLS 伪装域名)")"
    node_name="$(read_required "请输入节点名")"
}

collect_auto_config() {
    echo
    info "=== 全自动模式 ==="
    echo "除 SNI 外，其余字段使用默认值或自动生成"
    echo

    reality_sni="$(read_required "请输入 Reality SNI 域名 (TLS 伪装域名)")"

    ss_port="$SS_PORT_DEFAULT"
    reality_port="$REALITY_PORT_DEFAULT"
    node_name="$NODE_NAME_DEFAULT"
    ss_password="$(generate_ss_password)"
    uuid="$(generate_uuid)"
    reality_short_id="$(generate_short_id)"
    generate_reality_keypair

    echo
    info "=== 处理自动生成项 ==="
    echo "已生成 SS 密钥: $ss_password"
    echo "已生成 UUID: $uuid"
    echo "已生成 Reality 密钥对"
    echo "  PrivateKey: $reality_private_key"
    echo "  PublicKey:  $reality_public_key"
    echo "已生成 short_id: $reality_short_id"
}

collect_config() {
    echo
    info "=== 请选择配置模式 ==="
    echo "  1) 自定义模式  - 逐项填写端口/密钥/UUID/SNI/节点名 (共 8 项)"
    echo "  2) 全自动模式  - 仅输入 SNI，其余全部默认值或自动生成"
    read -rp "请选择 [1/2]: " mode

    case "$mode" in
        1)
            collect_custom_config
            ;;
        2|"")
            collect_auto_config
            ;;
        *)
            warn "输入无效，默认使用全自动模式"
            collect_auto_config
            ;;
    esac
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

write_config() {
    if [[ -f "$CONFIG_PATH" ]]; then
        local backup="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        warn "发现已存在配置，已备份为 ${backup}"
        run_as_root cp "$CONFIG_PATH" "$backup"
    fi

    local ss_password_e reality_private_key_e reality_short_id_e reality_sni_e uuid_e node_name_e
    ss_password_e="$(json_escape "$ss_password")"
    reality_private_key_e="$(json_escape "$reality_private_key")"
    reality_short_id_e="$(json_escape "$reality_short_id")"
    reality_sni_e="$(json_escape "$reality_sni")"
    uuid_e="$(json_escape "$uuid")"
    node_name_e="$(json_escape "$node_name")"

    run_as_root tee "$CONFIG_PATH" >/dev/null <<EOF
{
  "dns": {
    "servers": [
      { "tag": "cloudflare", "type": "udp", "server": "1.1.1.1" },
      { "tag": "google", "type": "udp", "server": "8.8.8.8" }
    ],
    "final": "cloudflare",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "tag": "SS-${node_name_e}",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": ${ss_port},
      "method": "${SS_METHOD_DEFAULT}",
      "password": "${ss_password_e}",
      "multiplex": {
        "enabled": true
      }
    },
    {
      "tag": "Reality-${node_name_e}",
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": ${reality_port},
      "users": [
        {
          "uuid": "${uuid_e}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni_e}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${reality_sni_e}",
            "server_port": 443
          },
          "private_key": "${reality_private_key_e}",
          "short_id": [
            "${reality_short_id_e}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": "cloudflare",
    "rules": [
      { "inbound": ["Reality-${node_name_e}", "SS-${node_name_e}"], "outbound": "direct" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/etc/sing-box/cache.db"
    }
  },
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  }
}
EOF
}

set_permissions() {
    echo "设置目录与配置权限..."
    run_as_root mkdir -p "$DATA_DIR" "$CONFIG_DIR"
    run_as_root chown -R sing-box:sing-box "$DATA_DIR" "$CONFIG_DIR"
    run_as_root chmod 640 "$CONFIG_PATH"
}

check_config() {
    echo "校验 sing-box 配置..."
    if ! run_as_root sing-box check -c "$CONFIG_PATH"; then
        error "配置校验失败，请检查输入内容"
        exit 1
    fi
    success "配置校验通过"
}

ensure_openrc_service() {
    if [[ -x "/etc/init.d/${SERVICE_NAME}" ]]; then
        return
    fi

    local sing_box_bin
    sing_box_bin="$(command -v sing-box)"

    echo "未找到 OpenRC 服务文件，正在创建 /etc/init.d/${SERVICE_NAME}..."
    run_as_root tee "/etc/init.d/${SERVICE_NAME}" >/dev/null <<EOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="sing-box service"
supervisor="supervise-daemon"
command="${sing_box_bin}"
command_args="run -c ${CONFIG_PATH} -D ${DATA_DIR}"
command_user="sing-box:sing-box"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF
    run_as_root chmod +x "/etc/init.d/${SERVICE_NAME}"
}

start_service_systemd() {
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    run_as_root systemctl restart "$SERVICE_NAME"

    sleep 1
    if run_as_root systemctl is-active --quiet "$SERVICE_NAME"; then
        success "sing-box 已启动并设置为开机自启"
        info "查看状态： sudo systemctl status ${SERVICE_NAME}"
        info "查看日志： sudo journalctl -u ${SERVICE_NAME} -f"
    else
        error "sing-box 启动失败，请运行 'sudo journalctl -u ${SERVICE_NAME} -e' 查看日志"
        exit 1
    fi
}

start_service_openrc() {
    ensure_openrc_service
    run_as_root rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    run_as_root rc-service "$SERVICE_NAME" restart

    sleep 1
    if run_as_root rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        success "sing-box 已启动并设置为开机自启"
        info "查看状态： rc-service ${SERVICE_NAME} status"
        info "查看日志： tail -f /var/log/sing-box.log /var/log/sing-box.err"
    else
        error "sing-box 启动失败，请运行 'rc-service ${SERVICE_NAME} status' 或查看 /var/log/sing-box.err"
        exit 1
    fi
}

start_service_manual_hint() {
    warn "未检测到 systemd 或 OpenRC，已跳过开机自启配置"
    info "可手动运行： sing-box run -c ${CONFIG_PATH} -D ${DATA_DIR}"
}

start_service() {
    echo "启用开机自启并启动 sing-box..."

    case "$SERVICE_MANAGER" in
        systemd)
            start_service_systemd
            ;;
        openrc)
            start_service_openrc
            ;;
        *)
            start_service_manual_hint
            ;;
    esac
}

main() {
    detect_os
    detect_service_manager
    install_sing_box
    ensure_sing_box_available
    ensure_sing_box_user
    run_as_root mkdir -p "$DATA_DIR" "$CONFIG_DIR"
    collect_config
    write_config
    set_permissions
    check_config
    start_service
}

main "$@"
