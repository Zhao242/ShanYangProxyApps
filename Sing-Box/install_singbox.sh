#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="${CONFIG_DIR}/config.json"

# ---------- 1. 安装 sing-box 稳定版 ----------
if command -v sing-box &> /dev/null; then
    echo -e "${CYAN}sing-box 已安装，跳过安装步骤${NC}"
else
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

    echo "正在安装 sing-box 稳定版..."
    sudo apt-get install sing-box -yq > /dev/null 2>&1

    if command -v sing-box &> /dev/null; then
        sing_box_version=$(sing-box version | grep 'sing-box version' | awk '{print $3}')
        echo -e "${GREEN}sing-box 安装成功，版本：${NC} $sing_box_version"
    else
        echo -e "${RED}sing-box 安装失败，请检查日志或网络配置${NC}"
        exit 1
    fi
fi

# ---------- 2. 创建用户与目录 ----------
if ! id sing-box &>/dev/null; then
    echo "正在创建 sing-box 系统用户..."
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
fi

sudo mkdir -p /var/lib/sing-box "${CONFIG_DIR}"

# ---------- 3. 收集用户输入 ----------
# 输入指令: b=返回上一项 / r=重头开始 / q=放弃配置退出
PROMPTS=(
    "请输入 Shadowsocks 密钥 (2022-blake3-aes-128-gcm，需 base64，16 字节)"
    "请输入 Reality private_key"
    "请输入 Reality short_id"
    "请输入 Reality SNI 域名 (将同时用于 server_name 和 handshake.server)"
)
LABELS=("SS 密钥" "Reality private_key" "Reality short_id" "Reality SNI")

collect_inputs() {
    VALUES=("" "" "" "")
    local i=0
    echo -e "\n${CYAN}=== 请输入节点配置参数 ===${NC}"
    echo -e "${YELLOW}提示: 输入 b 返回上一项, r 重头开始, q 放弃并退出${NC}\n"
    while [[ $i -lt ${#PROMPTS[@]} ]]; do
        local current="${VALUES[$i]}"
        local hint=""
        [[ -n "$current" ]] && hint=" [当前: ${current}，回车保留]"
        read -rp "[$((i+1))/${#PROMPTS[@]}] ${PROMPTS[$i]}${hint}: " ans
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
                VALUES=("" "" "" "")
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
                    echo -e "${RED}不能为空${NC}"
                fi
                ;;
            *)
                VALUES[$i]="$ans"
                i=$((i+1))
                ;;
        esac
    done
}

while true; do
    collect_inputs
    echo -e "\n${CYAN}=== 请确认以下配置 ===${NC}"
    for idx in "${!LABELS[@]}"; do
        echo -e "  ${LABELS[$idx]}: ${VALUES[$idx]}"
    done
    read -rp "确认无误? (y=确认 / r=重头修改 / q=退出): " confirm
    case "$confirm" in
        y|Y) break ;;
        q|Q) echo -e "${RED}已放弃配置，退出${NC}"; exit 1 ;;
        *) ;;
    esac
done

ss_password="${VALUES[0]}"
reality_private_key="${VALUES[1]}"
reality_short_id="${VALUES[2]}"
reality_sni="${VALUES[3]}"

# ---------- 4. 备份旧配置并写入新配置 ----------
if [[ -f "${CONFIG_PATH}" ]]; then
    backup="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${YELLOW}发现已存在配置，已备份为 ${backup}${NC}"
    sudo cp "${CONFIG_PATH}" "${backup}"
fi

# 转义 JSON 中的特殊字符（反斜杠和双引号）
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
ss_password_e=$(esc "$ss_password")
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
      "listen_port": 21958,
      "method": "2022-blake3-aes-128-gcm",
      "password": "${ss_password_e}",
      "multiplex": {
        "enabled": true
      }
    },
    {
      "tag": "Reality",
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": 21959,
      "users": [
        {
          "uuid": "4bd7d2f4-9f01-4596-b4d3-326d2f0b27e5",
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
