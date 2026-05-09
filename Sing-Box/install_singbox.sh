#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="${CONFIG_DIR}/config.json"

MODE=""

# ---------- 1. 安装 sing-box 稳定版 ----------
setup_repo() {
    echo -e "${CYAN}添加 sing-box 官方仓库...${NC}"
    sudo mkdir -p /etc/apt/keyrings
    sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    sudo chmod a+r /etc/apt/keyrings/sagernet.asc
    echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
" | sudo tee /etc/apt/sources.list.d/sagernet.sources > /dev/null

    echo "正在更新包列表，请稍候..."
    sudo apt-get update -qq > /dev/null 2>&1
}

install_action="install"
if command -v sing-box &> /dev/null; then
    current_version=$(sing-box version | grep 'sing-box version' | awk '{print $3}')
    echo -e "${CYAN}检测到已安装 sing-box，当前版本: ${current_version}${NC}"
    while true; do
        read -rp "请选择操作 (1=升级到最新稳定版 / 2=跳过安装 / q=退出): " choice
        case "$choice" in
            1) install_action="upgrade"; break ;;
            2) install_action="skip"; break ;;
            q|Q) echo "已退出"; exit 0 ;;
            *) echo -e "${RED}无效输入${NC}" ;;
        esac
    done
fi

case "$install_action" in
    install)
        setup_repo
        echo "正在安装 sing-box 稳定版..."
        sudo apt-get install sing-box -yq > /dev/null 2>&1
        ;;
    upgrade)
        setup_repo
        echo "正在升级 sing-box 到最新稳定版..."
        sudo apt-get install --only-upgrade sing-box -yq > /dev/null 2>&1
        ;;
    skip)
        echo "跳过安装步骤"
        ;;
esac

if command -v sing-box &> /dev/null; then
    sing_box_version=$(sing-box version | grep 'sing-box version' | awk '{print $3}')
    echo -e "${GREEN}sing-box 可用，版本：${NC} $sing_box_version"
else
    echo -e "${RED}sing-box 不可用，请检查日志或网络配置${NC}"
    exit 1
fi

# ---------- 2. 创建用户与目录 ----------
if ! id sing-box &>/dev/null; then
    echo "正在创建 sing-box 系统用户..."
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
fi

sudo mkdir -p /var/lib/sing-box "${CONFIG_DIR}"

# ---------- 3. 收集用户输入 ----------
# 输入指令: b=返回上一项 / r=重头开始 / q=放弃配置退出
HOSTNAME_VAL=$(hostname)
SS_METHOD="2022-blake3-aes-128-gcm"

PROMPTS=(
    "SS 监听端口"
    "SS 密钥 (${SS_METHOD}, base64 16字节)"
    "Reality 监听端口"
    "Reality UUID"
    "Reality private_key"
    "Reality short_id"
    "Reality SNI 域名 (TLS 伪装域名，必填)"
    "节点名前缀"
)
LABELS=(
    "SS 端口"
    "SS 密钥"
    "Reality 端口"
    "Reality UUID"
    "Reality private_key"
    "Reality short_id"
    "Reality SNI"
    "节点名前缀"
)
# 回车时的处理: 字面值 / <auto>=自动生成 / <required>=必填
DEFAULTS=(
    "21958"
    "<auto>"
    "21959"
    "<auto>"
    "<auto>"
    "<auto>"
    "<required>"
    "${HOSTNAME_VAL}"
)

# 显示用的提示后缀
hint_for() {
    case "${DEFAULTS[$1]}" in
        "<auto>")     printf " [回车自动生成]" ;;
        "<required>") printf " [必填]" ;;
        *)            printf " [回车默认: %s]" "${DEFAULTS[$1]}" ;;
    esac
}

collect_inputs() {
    VALUES=("" "" "" "" "" "" "" "")
    local i=0
    local total=${#PROMPTS[@]}
    echo -e "\n${CYAN}=== 请输入节点配置参数 ===${NC}"
    echo -e "${YELLOW}提示: 输入 b 返回上一项, r 重头开始, q 放弃并退出${NC}\n"
    while [[ $i -lt $total ]]; do
        local current="${VALUES[$i]}"
        local hint
        if [[ -n "$current" ]]; then
            hint=" [当前: ${current}，回车保留]"
        else
            hint=$(hint_for $i)
        fi
        read -rp "[$((i+1))/${total}] ${PROMPTS[$i]}${hint}: " ans
        case "$ans" in
            b|B)
                if [[ $i -eq 0 ]]; then
                    echo -e "${YELLOW}已是第一项，无法返回${NC}"
                else
                    i=$((i-1))
                fi
                ;;
            r|R)
                echo -e "${YELLOW}已重置，从头开始${NC}"
                VALUES=("" "" "" "" "" "" "" "")
                i=0
                ;;
            q|Q)
                echo -e "${RED}已放弃配置，退出${NC}"
                exit 1
                ;;
            "")
                if [[ -n "$current" ]]; then
                    i=$((i+1))
                else
                    case "${DEFAULTS[$i]}" in
                        "<required>")
                            echo -e "${RED}此项必填，不能为空${NC}"
                            ;;
                        *)
                            VALUES[$i]="${DEFAULTS[$i]}"
                            i=$((i+1))
                            ;;
                    esac
                fi
                ;;
            *)
                VALUES[$i]="$ans"
                i=$((i+1))
                ;;
        esac
    done
}

echo -e "\n${CYAN}=== 请选择配置模式 ===${NC}"
echo "  1) 自定义模式  - 逐项填写端口/密钥/UUID/SNI/节点名 (共 8 项)"
echo "  2) 全自动模式  - 仅输入 SNI，其余全部默认值或自动生成"
while true; do
    read -rp "请选择 [1/2]: " mode_choice
    case "$mode_choice" in
        1) MODE="full"; break ;;
        2) MODE="quick"; break ;;
        *) echo -e "${RED}无效输入，请输入 1 或 2${NC}" ;;
    esac
done

if [[ "$MODE" == "quick" ]]; then
    echo -e "\n${CYAN}=== 全自动模式 ===${NC}"
    echo -e "${YELLOW}除 SNI 外，其余字段使用默认值或自动生成${NC}\n"
    while true; do
        read -rp "请输入 Reality SNI 域名 (TLS 伪装域名): " quick_sni
        [[ -n "$quick_sni" ]] && break
        echo -e "${RED}SNI 不能为空${NC}"
    done
    VALUES=(
        "21958"
        "<auto>"
        "21959"
        "<auto>"
        "<auto>"
        "<auto>"
        "$quick_sni"
        "${HOSTNAME_VAL}"
    )
else
    while true; do
        collect_inputs
        echo -e "\n${CYAN}=== 请确认以下配置 ===${NC}"
        for idx in "${!LABELS[@]}"; do
            disp_v="${VALUES[$idx]}"
            [[ "$disp_v" == "<auto>" ]] && disp_v="${YELLOW}<将自动生成>${NC}"
            echo -e "  ${LABELS[$idx]}: ${disp_v}"
        done
        read -rp "确认无误? (y=确认 / r=重头修改 / q=退出): " confirm
        case "$confirm" in
            y|Y) break ;;
            q|Q) echo -e "${RED}已放弃配置，退出${NC}"; exit 1 ;;
            *) ;;
        esac
    done
fi

ss_port="${VALUES[0]}"
ss_password="${VALUES[1]}"
reality_port="${VALUES[2]}"
reality_uuid="${VALUES[3]}"
reality_private_key="${VALUES[4]}"
reality_short_id="${VALUES[5]}"
reality_sni="${VALUES[6]}"
name_prefix="${VALUES[7]}"
reality_public_key=""

# ---------- 3.5 自动生成空缺字段 / 收集额外公钥 ----------
echo -e "\n${CYAN}=== 处理自动生成项 ===${NC}"

if [[ "$ss_password" == "<auto>" ]]; then
    ss_password=$(sing-box generate rand --base64 16)
    echo -e "${GREEN}已生成 SS 密钥:${NC} $ss_password"
fi

if [[ "$reality_uuid" == "<auto>" ]]; then
    reality_uuid=$(sing-box generate uuid)
    echo -e "${GREEN}已生成 UUID:${NC} $reality_uuid"
fi

if [[ "$reality_private_key" == "<auto>" ]]; then
    keypair=$(sing-box generate reality-keypair)
    reality_private_key=$(echo "$keypair" | awk -F': *' '/PrivateKey/ {print $2}')
    reality_public_key=$(echo "$keypair" | awk -F': *' '/PublicKey/ {print $2}')
    echo -e "${GREEN}已生成 Reality 密钥对${NC}"
    echo -e "  PrivateKey: $reality_private_key"
    echo -e "  PublicKey:  $reality_public_key"
else
    while true; do
        read -rp "请输入与该 private_key 对应的 public_key (用于客户端连接链接): " reality_public_key
        [[ -n "$reality_public_key" ]] && break
        echo -e "${RED}不能为空${NC}"
    done
fi

if [[ "$reality_short_id" == "<auto>" ]]; then
    reality_short_id=$(sing-box generate rand 8 --hex)
    echo -e "${GREEN}已生成 short_id:${NC} $reality_short_id"
fi

# ---------- 4. 写入新配置 ----------
# 转义 JSON 中的特殊字符（反斜杠和双引号）
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
ss_password_e=$(esc "$ss_password")
reality_uuid_e=$(esc "$reality_uuid")
reality_private_key_e=$(esc "$reality_private_key")
reality_short_id_e=$(esc "$reality_short_id")
reality_sni_e=$(esc "$reality_sni")

sudo tee "${CONFIG_PATH}" > /dev/null <<EOF
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
      "tag": "SS",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": ${ss_port},
      "method": "${SS_METHOD}",
      "password": "${ss_password_e}",
      "multiplex": {
        "enabled": true
      }
    },
    {
      "tag": "Reality",
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": ${reality_port},
      "users": [
        {
          "uuid": "${reality_uuid_e}",
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
      { "inbound": ["Reality","SS"], "outbound": "direct" }
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

# ---------- 5. 设置权限 ----------
echo "设置目录与配置权限..."
sudo chown -R sing-box:sing-box /var/lib/sing-box "${CONFIG_DIR}"
sudo chmod 640 "${CONFIG_PATH}"

# ---------- 6. 校验配置 ----------
echo "校验 sing-box 配置..."
if ! sudo sing-box check -c "${CONFIG_PATH}"; then
    echo -e "${RED}配置校验失败，请检查输入内容${NC}"
    exit 1
fi
echo -e "${GREEN}配置校验通过${NC}"

# ---------- 7. 设置开机自启并启动 ----------
echo "启用开机自启并启动 sing-box..."
sudo systemctl daemon-reload
sudo systemctl enable sing-box >/dev/null 2>&1
sudo systemctl restart sing-box

sleep 1
if sudo systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}sing-box 已启动并设置为开机自启${NC}"
    echo -e "${CYAN}查看状态：${NC} sudo systemctl status sing-box"
    echo -e "${CYAN}查看日志：${NC} sudo journalctl -u sing-box -f"
else
    echo -e "${RED}sing-box 启动失败，请运行 'sudo journalctl -u sing-box -e' 查看日志${NC}"
    exit 1
fi

# ---------- 8. 输出客户端连接链接 ----------
echo -e "\n${CYAN}=== 探测服务器公网 IP ===${NC}"
ipv4=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
ipv6=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
[[ -n "$ipv4" ]] && echo -e "IPv4: ${GREEN}${ipv4}${NC}" || echo -e "IPv4: ${YELLOW}未检测到${NC}"
[[ -n "$ipv6" ]] && echo -e "IPv6: ${GREEN}${ipv6}${NC}" || echo -e "IPv6: ${YELLOW}未检测到${NC}"

ss_userinfo=$(printf '%s' "${SS_METHOD}:${ss_password}" | base64 -w0)

LINKS_FILE="${CONFIG_DIR}/client-links.txt"
{
    echo "# sing-box client links — generated $(date -Iseconds)"
    echo
    if [[ -n "$ipv4" ]]; then
        echo "[SS-IPv4]"
        echo "ss://${ss_userinfo}@${ipv4}:${ss_port}#${name_prefix}-SS-v4"
        echo
        echo "[Reality-IPv4]"
        echo "vless://${reality_uuid}@${ipv4}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_short_id}&type=tcp&headerType=none#${name_prefix}-Reality-v4"
        echo
    fi
    if [[ -n "$ipv6" ]]; then
        echo "[SS-IPv6]"
        echo "ss://${ss_userinfo}@[${ipv6}]:${ss_port}#${name_prefix}-SS-v6"
        echo
        echo "[Reality-IPv6]"
        echo "vless://${reality_uuid}@[${ipv6}]:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_short_id}&type=tcp&headerType=none#${name_prefix}-Reality-v6"
        echo
    fi
} | sudo tee "${LINKS_FILE}" > /dev/null
sudo chown sing-box:sing-box "${LINKS_FILE}" 2>/dev/null || true
sudo chmod 640 "${LINKS_FILE}"

echo -e "\n${CYAN}=== 客户端连接链接 ===${NC}"
if [[ -n "$ipv4" ]]; then
    echo -e "${GREEN}SS (IPv4):${NC}"
    echo "  ss://${ss_userinfo}@${ipv4}:${ss_port}#${name_prefix}-SS-v4"
    echo -e "${GREEN}Reality (IPv4):${NC}"
    echo "  vless://${reality_uuid}@${ipv4}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_short_id}&type=tcp&headerType=none#${name_prefix}-Reality-v4"
fi
if [[ -n "$ipv6" ]]; then
    echo -e "${GREEN}SS (IPv6):${NC}"
    echo "  ss://${ss_userinfo}@[${ipv6}]:${ss_port}#${name_prefix}-SS-v6"
    echo -e "${GREEN}Reality (IPv6):${NC}"
    echo "  vless://${reality_uuid}@[${ipv6}]:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_short_id}&type=tcp&headerType=none#${name_prefix}-Reality-v6"
fi
echo -e "\n${YELLOW}以上链接已保存至 ${LINKS_FILE}${NC}"

# 保存所有原始字段，方便备份/恢复
SECRETS_FILE="${CONFIG_DIR}/secrets.txt"
sudo tee "${SECRETS_FILE}" > /dev/null <<EOF
# sing-box secrets — generated $(date -Iseconds)
# 备份此文件即可保留全部连接所需字段（含 public_key）
SS_METHOD=${SS_METHOD}
SS_PORT=${ss_port}
SS_PASSWORD=${ss_password}
REALITY_PORT=${reality_port}
REALITY_UUID=${reality_uuid}
REALITY_PRIVATE_KEY=${reality_private_key}
REALITY_PUBLIC_KEY=${reality_public_key}
REALITY_SHORT_ID=${reality_short_id}
REALITY_SNI=${reality_sni}
NAME_PREFIX=${name_prefix}
EOF
sudo chown root:root "${SECRETS_FILE}"
sudo chmod 600 "${SECRETS_FILE}"

echo -e "${YELLOW}原始凭据已保存至 ${SECRETS_FILE} (root 600)${NC}"
echo -e "${YELLOW}备份命令: sudo tar czf singbox-backup.tar.gz -C /etc sing-box/${NC}"

# ---------- 9. 自删除安装脚本 ----------
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
if [[ -f "$SCRIPT_PATH" ]]; then
    rm -f -- "$SCRIPT_PATH" && echo -e "${CYAN}安装脚本已自动删除: ${SCRIPT_PATH}${NC}"
fi
