#!/usr/bin/env bash
# SSH 加固脚本: 添加公钥 + 启用密钥登录 + 禁用密码登录 + 修改端口
# 用法: sudo bash ssh_setup.sh   (全程交互式输入)

set -euo pipefail

#======== 必须 root ========
if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 或 sudo 运行" >&2
    exit 1
fi

# 让 read 即使在管道里也能从终端读取
TTY=/dev/tty
[[ -r $TTY ]] || { echo "需要交互终端" >&2; exit 1; }

echo "=================================================="
echo "        SSH 加固脚本 (交互式)"
echo "=================================================="

#======== 1. 选择目标用户 ========
DEFAULT_USER="${SUDO_USER:-root}"
read -rp "为哪个用户配置密钥? [回车=${DEFAULT_USER}]: " TARGET_USER < $TTY
TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "用户不存在: $TARGET_USER" >&2
    exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || { echo "找不到用户主目录: $TARGET_HOME" >&2; exit 1; }

#======== 2. 输入端口 ========
while :; do
    read -rp "新的 SSH 端口号 (1-65535, 推荐 1024-65535 之间): " PORT < $TTY
    if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
        break
    fi
    echo "  -> 端口无效,请重新输入"
done

#======== 3. 输入公钥 ========
echo
echo "请粘贴公钥内容 (单行, 形如 'ssh-ed25519 AAAA... user@host')"
echo "输入完成后按回车:"
read -r PUBKEY < $TTY

if ! [[ "$PUBKEY" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
    echo "公钥格式不正确" >&2
    exit 1
fi

#======== 4. 二次确认 ========
echo
echo "--------- 即将执行 ---------"
echo "  目标用户: $TARGET_USER ($TARGET_HOME)"
echo "  SSH 端口: $PORT"
echo "  公钥指纹: $(echo "$PUBKEY" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo '(无法计算)')"
echo "  操作: 添加公钥 / 启用密钥登录 / 禁用密码登录"
echo "----------------------------"
read -rp "确认执行? [y/N]: " CONFIRM < $TTY
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

#======== 5. 写入公钥 ========
SSH_DIR="$TARGET_HOME/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
touch "$AUTH_FILE"

if grep -qxF "$PUBKEY" "$AUTH_FILE"; then
    echo "[=] 公钥已存在,跳过"
else
    echo "$PUBKEY" >> "$AUTH_FILE"
    echo "[+] 公钥已添加"
fi

chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_FILE"

#======== 6. 备份 sshd_config ========
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$SSHD_CONFIG" "$BACKUP"
echo "[+] 已备份配置: $BACKUP"

#======== 7. 修改 sshd_config ========
set_config() {
    local key="$1" val="$2"
    if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
        sed -ri "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$SSHD_CONFIG"
    else
        echo "${key} ${val}" >> "$SSHD_CONFIG"
    fi
}

set_config "Port"                            "$PORT"
set_config "PubkeyAuthentication"            "yes"
set_config "PasswordAuthentication"          "no"
set_config "ChallengeResponseAuthentication" "no"
set_config "KbdInteractiveAuthentication"    "no"
set_config "UsePAM"                          "yes"
set_config "PermitRootLogin"                 "prohibit-password"

# 处理 sshd_config.d/ 下 cloud-init 等覆盖文件
if [[ -d /etc/ssh/sshd_config.d ]]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        sed -ri 's|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication no|I' "$f"
    done
fi

#======== 8. 校验配置 ========
if ! sshd -t; then
    echo "[!] sshd 配置校验失败,正在回滚..." >&2
    cp -a "$BACKUP" "$SSHD_CONFIG"
    exit 1
fi
echo "[+] sshd 配置校验通过"

#======== 9. 防火墙放行新端口 ========
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" || true
    echo "[+] ufw 已放行 ${PORT}/tcp"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --reload || true
    echo "[+] firewalld 已放行 ${PORT}/tcp"
fi

#======== 10. SELinux ========
if command -v semanage >/dev/null 2>&1 && getenforce 2>/dev/null | grep -qiE 'enforcing|permissive'; then
    semanage port -a -t ssh_port_t -p tcp "$PORT" 2>/dev/null \
        || semanage port -m -t ssh_port_t -p tcp "$PORT" 2>/dev/null \
        || true
    echo "[+] SELinux 端口标签已更新"
fi

#======== 11. 重启 sshd ========
echo "[*] 重启 sshd..."
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    systemctl restart ssh
elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    systemctl restart sshd
else
    service ssh restart 2>/dev/null || service sshd restart
fi

#======== 12. 输出生效后的实际配置 ========
echo
echo "--------- 当前生效的 SSH 配置 ---------"
# sshd -T 输出的是 sshd 实际运行时解析后的最终值(包含 sshd_config.d 合并结果)
if sshd -T 2>/dev/null | grep -iE '^(port|pubkeyauthentication|passwordauthentication|challengeresponseauthentication|kbdinteractiveauthentication|permitrootlogin|usepam)[[:space:]]'; then
    :
else
    echo "(sshd -T 不可用,回退显示 sshd_config 中的相关行:)"
    grep -iE '^[[:space:]]*(Port|PubkeyAuthentication|PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication|PermitRootLogin|UsePAM)[[:space:]]' "$SSHD_CONFIG"
fi
echo "--------------------------------------"

# 实际监听端口验证
if command -v ss >/dev/null 2>&1; then
    echo "[*] sshd 实际监听:"
    ss -ltnp 2>/dev/null | grep -i sshd || echo "(未检测到 sshd 监听,请检查服务状态)"
fi

echo
echo "=================================================="
echo " 完成! 请用新端口测试登录 (不要关闭当前会话):"
echo "   ssh -p $PORT $TARGET_USER@<服务器IP>"
echo " 确认能登录后再断开当前 SSH 会话!"
echo " 配置备份: $BACKUP"
echo "=================================================="

#======== 13. 自删除脚本 ========
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [[ -f "$SCRIPT_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    echo "[+] 脚本已删除: $SCRIPT_PATH"
fi
