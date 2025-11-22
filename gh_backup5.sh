#!/data/data/com.termux/files/usr/bin/bash
# GitHub 高级备份系统 v2.0
# 功能：增量备份、多线程、大文件分块、Release整理、HTML仪表盘、脚本自愈

########################################
# 配置加载
########################################
if [ ! -f "./config.sh" ]; then
    echo "错误：找不到 config.sh"
    exit 1
fi
source ./config.sh

if [ -z "$GITHUB_TOKEN" ] || [ -z "$MY_GH_NAME" ] || [ -z "$PREFIX" ]; then
    echo "错误：config.sh 信息不完整"
    exit 1
fi

SCRIPT_PATH="$(realpath "$0")"

########################################
# 工具函数
########################################

# ---- 脚本完整性检查 ----
calc_md5() { md5sum "$1" | awk '{print $1}'; }
download_file() { curl -L --retry 3 --retry-delay 2 -o "$1" "$2"; }

integrity_check() {
    echo "[*] 正在检查脚本完整性..."
    local current_md5=$(calc_md5 "$SCRIPT_PATH")
    local remote_md5_file=".gh_backup_latest_md5"
    download_file "$remote_md5_file" "$REMOTE_MD5_URL" || { echo "[!] 无法下载远程 md5，跳过"; return; }
    local remote_md5=$(cat "$remote_md5_file")
    rm "$remote_md5_file"

    if [ "$current_md5" != "$remote_md5" ]; then
        echo "[!!] 脚本损坏，尝试自动恢复..."
        local tmp_new="./gh_backup_new.sh"
        download_file "$tmp_new" "$REMOTE_SCRIPT_URL" || { echo "[!!!] 无法恢复"; exit 1; }
        mv "$tmp_new" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo "[✔] 脚本已恢复，请重新运行"
        exit 0
    fi
    echo "[OK] 脚本完整性正常"
}

#integrity_check

# ---- 重试 curl 下载 ----
retry_curl() {
    local url="$1" out="$2" max=5 count=0
    while true; do
        if [ -z "$out" ]; then curl -L --retry 3 --retry-delay 2 "$url" && break
        else curl -L --retry 3 --retry-delay 2 -o "$out" "$url" && break
        fi
        count=$((count+1))
        echo "curl失败，重试 $count/$max..."
        [ $count -ge $max ] && { echo "[!] 下载失败: $url"; return 1; }
        sleep 2
    done
}

retry_curl_upload() {
    local cmd="$1" max=5 count=0
    while true; do
        eval "$cmd" && break
        count=$((count+1))
        echo "上传失败，重试 $count/$max..."
        [ $count -ge $max ] && { echo "[!] 上传失败"; return 1; }
        sleep 2
    done
}

# ---- 大文件分块下载 ----
retry_curl_range() {
    local url="$1" output="$2" start="$3" end="$4" max=5 count=0
    while true; do
        curl -L -H "Range: bytes=$start-$end" --retry 3 --retry-delay 2 -o chunk.tmp "$url" && break
        count=$((count+1))
        echo "区段下载失败，重试 $count/$max..."
        [ $count -ge $max ] && return 1
        sleep 2
    done
    cat chunk.tmp >> "$output"
    rm chunk.tmp
}

chunk_download() {
    local url="$1" output="$2" chunk_size=104857600 start=0
    local total=$(curl -sI "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')
    [ -z "$total" ] || [ "$total" = "0" ] && { echo "[!] 无法获取大小"; return 1; }
    : > "$output"
    while [ "$start" -lt "$total" ]; do
        end=$((start+chunk_size-1))
        [ "$end" -ge "$total" ] && end=$((total-1))
        echo "下载区段：$start-$end"
        retry_curl_range "$url" "$output" "$start" "$end" || return 1
        start=$((end+1))
    done
}

# ---- 多线程控制 ----
running_jobs=0
run_with_thread_control() {
    while [ "$running_jobs" -ge "$MAX_THREADS" ]; do wait -n; running_jobs=$((running_jobs-1)); done
    "$@" &
    running_jobs=$((running_jobs+1))
}
wait_all_jobs() { wait; }

########################################
# repos.txt 检查
########################################
if [ ! -f "./repos.txt" ]; then
    echo "错误：找不到 repos.txt"
    exit 1
fi
REPOS=$(cat repos.txt)

########################################
# HTML 仪表盘模板
########################################
DATE=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="backup_dashboard_${DATE}.html"
TABLE_ROWS=""
SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

########################################
# 单个仓库备份函数
########################################
backup_one_repo() {
    local SOURCE_REPO="$1"
    local OWNER=$(echo "$SOURCE_REPO" | cut -d'/' -f1)
    local REPO=$(echo "$SOURCE_REPO" | cut -d'/' -f2)
    local TARGET_REPO="${PREFIX}-${OWNER}-${REPO}"
    local STATUS="" LATEST_COMMIT="" RELEASE_COUNT=0 ASSETS_COUNT=0

    echo "========== 处理 $SOURCE_REPO =========="

    # 检查是否存在
    local HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://api.github.com/repos/$SOURCE_REPO)
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "[跳过] 仓库不存在或私有"
        STATUS="skip"
        TABLE_ROWS+="<tr><td>$SOURCE_REPO</td><td>$TARGET_REPO</td><td class='$STATUS'>跳过</td><td>-</td><td>-</td><td>-</td><td>$(date)</td></tr>"
        SKIP_COUNT=$((SKIP_COUNT+1))
        return
    fi

    # 最新 commit
    LATEST_COMMIT=$(curl -s https://api.github.com/repos/$SOURCE_REPO/commits | jq -r '.[0].sha')

    # 检查备份仓库最新 commit
    local TGT_COMMIT=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/$MY_GH_NAME/$TARGET_REPO/commits 2>/dev/null | jq -r '.[0].sha')

    if [ "$LATEST_COMMIT" = "$TGT_COMMIT" ] && [ "$TGT_COMMIT" != "null" ]; then
        echo "[跳过] 无更新"
        STATUS="skip"
        TABLE_ROWS+="<tr><td>$SOURCE_REPO</td><td>$TARGET_REPO</td><td class='$STATUS'>跳过</td><td>$LATEST_COMMIT</td><td>-</td><td>-</td><td>$(date)</td></tr>"
        SKIP_COUNT=$((SKIP_COUNT+1))
        return
    fi

    # 创建仓库
    local CHECK=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/$MY_GH_NAME/$TARGET_REPO)
    if echo "$CHECK" | grep -q "Not Found"; then
        echo "[+] 创建备份仓库 $TARGET_REPO"
        curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" -d "{\"name\": \"$TARGET_REPO\"}" https://api.github.com/user/repos >/dev/null
    fi

    # 克隆 & 推送
    rm -rf "$TARGET_REPO"
    git clone --mirror "https://github.com/$SOURCE_REPO.git" "$TARGET_REPO"
    cd "$TARGET_REPO"
    git remote remove backup 2>/dev/null
    git remote add backup "https://$GITHUB_TOKEN@github.com/$MY_GH_NAME/$TARGET_REPO.git"
    git push backup --mirror
    cd ..

    # 备份 Releases + Assets
    local RELEASES=$(curl -s https://api.github.com/repos/$SOURCE_REPO/releases)
    RELEASE_COUNT=$(echo "$RELEASES" | jq 'length')
    echo "$RELEASES" | jq -c '.[]' | while read rel; do
        local TAG=$(echo "$rel" | jq -r '.tag_name')
        # 时间前缀整理
        local CREATED=$(echo "$rel" | jq -r '.created_at')
        if [[ ! "$TAG" =~ ^[0-9]{8}_ ]]; then
            local NEW_TAG="$(date -d "$CREATED" +%Y%m%d)_$TAG"
            curl -s -X PATCH -H "Authorization: token $GITHUB_TOKEN" -d "{\"name\":\"$NEW_TAG\"}" "https://api.github.com/repos/$MY_GH_NAME/$TARGET_REPO/releases/$(echo "$rel" | jq -r '.id')" >/dev/null
        fi
        # 下载 Assets
        local ASSETS=$(echo "$rel" | jq -c '.assets[]?')
        echo "$ASSETS" | while read asset; do
            [ -z "$asset" ] && continue
            local NAME=$(echo "$asset" | jq -r '.name')
            local URL=$(echo "$asset" | jq -r '.browser_download_url')
            size=$(curl -sI "$URL" | grep -i Content-Length | awk '{print $2}')
            if [ "$size" -gt 2000000000 ]; then chunk_download "$URL" "$NAME"; else retry_curl "$URL" "$NAME"; fi
            local UPLOAD_URL=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$MY_GH_NAME/$TARGET_REPO/releases/tags/$TAG" | jq -r '.upload_url' | sed 's/{?name,label}//')
            retry_curl_upload "curl -s -X POST -H 'Authorization: token $GITHUB_TOKEN' -H 'Content-Type: application/octet-stream' --data-binary @\"$NAME\" \"$UPLOAD_URL?name=$NAME\" >/dev/null"
            rm "$NAME"
            ASSETS_COUNT=$((ASSETS_COUNT+1))
        done
    done

    # 删除本地镜像
    rm -rf "$TARGET_REPO"

    STATUS="success"
    SUCCESS_COUNT=$((SUCCESS_COUNT+1))
    TABLE_ROWS+="<tr><td>$SOURCE_REPO</td><td>$TARGET_REPO</td><td class='$STATUS'>成功</td><td>$LATEST_COMMIT</td><td>$RELEASE_COUNT</td><td>$ASSETS_COUNT</td><td>$(date)</td></tr>"
}

########################################
# 批量多线程备份
########################################
for SOURCE_REPO in $REPOS; do
    run_with_thread_control backup_one_repo "$SOURCE_REPO"
done
wait_all_jobs

########################################
# 生成 HTML 仪表盘
########################################
cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>GitHub Backup Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body { background: #111; color: #eee; font-family: Arial; }
h2 { text-align:center; }
table { width:100%; border-collapse: collapse; margin-top:20px; }
th,td{border:1px solid #444; padding:6px; text-align:center;}
th{background:#222;}
.success{color:#8f8;} .skip{color:#ff8;} .fail{color:#f88;}
.container{width:90%; margin:auto;}
</style>
</head>
<body>
<div class="container">
<h2>GitHub Backup Dashboard - $DATE</h2>
<canvas id="statusChart" width="400" height="100"></canvas>
<table>
<tr>
<th>源仓库</th><th>备份仓库</th><th>状态</th><th>最新 Commit/Tag</th><th>Release 数量</th><th>Assets 数量</th><th>时间</th>
</tr>
$TABLE_ROWS
</table>
</div>
<script>
const ctx = document.getElementById('statusChart').getContext('2d');
const data = { labels:['成功','跳过','失败'], datasets:[{label:'仓库状态统计', data:[$SUCCESS_COUNT,$SKIP_COUNT,$FAIL_COUNT], backgroundColor:['#8f8','#ff8','#f88']}]};
new Chart(ctx,{ type:'bar', data });
</script>
</body>
</html>
EOF

echo "[✔] HTML 仪表盘生成完毕：$REPORT_FILE"
