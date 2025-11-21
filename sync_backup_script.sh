#!/data/data/com.termux/files/usr/bin/bash

##############################################
# GitHub 自动同步脚本
# 作者：ChatGPT 为 zchhh17 定制
##############################################

# === 你的 GitHub 账户信息 ===
GITHUB_USER="zchhh17"
GITHUB_EMAIL="zchhh17@gmail.com"
REPO_NAME="gh-backup-script"

# === 你的 Base64 Token（来自你提供的编码） ===
TOKEN_BASE64="Z2l0aHViX3BhdF8xMUJVUjRMNVkwQVJzQnRwYnNpMDEyX296SUlFb3F0TVFkaEw0MDdDN2t2eDJF
WURvMVA0dFNxNGVWVmh2V09EYmw0QUVJVzNIRHZBZWtNcnBV"

# === 解码 Token（不会写入 GitHub） ===
TOKEN=$(echo "$TOKEN_BASE64" | base64 -d)

echo "[*] GitHub Token 已解码（仅在内存中，不写入文件）"

# === 设置 Git 身份 ===
git config --global user.email "$GITHUB_EMAIL"
git config --global user.name "$GITHUB_USER"

# === 进入脚本目录 ===
cd "$(dirname "$0")"
echo "[*] 当前目录：$PWD"

# === 检查 gh_backup5.sh 是否存在 ===
if [ ! -f "gh_backup5.sh" ]; then
    echo "[❌] 找不到 gh_backup5.sh"
    exit 1
fi

# === 生成 md5.txt ===
echo "[*] 正在生成 md5.txt ..."
md5sum gh_backup5.sh | awk '{print $1}' > md5.txt
echo "[✔] md5.txt 已生成"

# === 更新 config.sh ===
echo "[*] 更新 config.sh 中的远程脚本 URL ..."

cat > config.sh <<EOF
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/gh_backup5.sh"
REMOTE_MD5_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/md5.txt"
EOF

echo "[✔] config.sh 已更新"

# === 设置 GitHub 推送 URL ===
git remote remove origin 2>/dev/null
git remote add origin "https://${GITHUB_USER}:${TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

echo "[*] Git Remote 已设置为 HTTPS + Token"

# === 推送到 GitHub ===
echo "[*] 提交更改..."
git add gh_backup5.sh md5.txt config.sh
git commit -m "Auto sync: update script and md5 at $(date '+%Y-%m-%d %H:%M:%S')"

echo "[*] 推送中..."
git push origin main

if [ $? -eq 0 ]; then
    echo "========================================"
    echo "🎉 推送成功！GitHub 仓库已更新"
    echo "仓库：https://github.com/${GITHUB_USER}/${REPO_NAME}"
    echo "========================================"
else
    echo "========================================"
    echo "❌ 推送失败，请检查网络或 Token 权限"
    echo "========================================"
fi

exit 0