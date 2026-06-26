#!/bin/bash

INSTALL_PATH="/usr/local/bin/cfy_ip"

if [ "$0" != "$INSTALL_PATH" ]; then
    echo "正在安装 [cfy 全量极致稳定版测速器]..."

    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 安装需要管理员权限。请使用 'curl ... | sudo bash' 或 'sudo bash <(curl ...)' 命令来运行。"
        exit 1
    fi
    
    echo "正在将脚本写入到 $INSTALL_PATH..."
    
    if [[ "$(basename "$0")" == "bash" || "$(basename "$0")" == "sh" || "$(basename "$0")" == "-bash" ]]; then
        if ! cat /proc/self/fd/0 > "$INSTALL_PATH"; then
            echo "❌ 写入脚本失败 (管道模式)，请重试。"
            exit 1
        fi
    else
        if ! cp "$0" "$INSTALL_PATH"; then
            echo "❌ 复制脚本失败 (文件模式)，请重试。"
            exit 1
        fi
    fi

    if [ $? -eq 0 ]; then
        chmod +x "$INSTALL_PATH"
        echo "✅ 安装成功! 您现在可以随时随地运行 'cfy_ip' 命令。"
        echo "---"
        echo "首次运行..."
        exec "$INSTALL_PATH"
    else
        echo "❌ 安装后赋权失败, 请检查权限。"
        exit 1
    fi
    exit 0
fi

# --- 主程序从这里开始 ---

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_deps() {
    for cmd in curl grep sed mktemp paste ping bc awk sort uniq; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它(特别是 bc 计算器).${NC}"
            exit 1
        fi
    done
}

get_optimized_ips() {
    local url_source1="https://www.wetest.vip/page/cloudflare/address_v4.html"
    local url_source2="https://raw.githubusercontent.com/ymyuuu/IPDB/refs/heads/main/BestCF/bestcfv4.txt"
    
    raw_data_file=$(mktemp)
    local tmp_all_source=$(mktemp)
    trap 'rm -f "$tmp_all_source"' RETURN

    echo -e "${YELLOW}正在拉取全部源数据 (全量无删减)...${NC}"
    
    # 抓取源 1 (wetest.vip)
    local html_content=$(curl -s --connect-timeout 8 "$url_source1")
    if [ -n "$html_content" ]; then 
        local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
        local ips1=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
        local isps1=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
        paste -d'|' <(echo "$ips1") <(echo "$isps1") >> "$tmp_all_source"
    fi

    # 抓取源 2 (GitHub 纯文本)
    local github_content=$(curl -s --connect-timeout 8 "$url_source2")
    if [ -n "$github_content" ]; then
        # 统一把 #、空格、逗号替换为 |
        echo "$github_content" | sed 's/[#, ]/|/g' >> "$tmp_all_source"
    fi

    # 【核心升级】使用强大的正则表达式，精准提取出所有包含合法 IPv4 地址的行，并全量去重
    awk -F'|' '
    {
        # 正则匹配标准的 IPv4 格式
        if ($1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
            if (!seen[$1]++) {
                print $1"|"$2
            }
        }
    }' "$tmp_all_source" > "$raw_data_file"

    local total_ips=$(wc -l < "$raw_data_file")
    if [ "$total_ips" -eq 0 ]; then 
        echo -e "${RED}❌ 所有源均获取失败或未提取到有效 IPv4，请检查网络。${NC}"
        return 1
    fi

    echo -e "${GREEN}全量提取成功！已捕获 $total_ips 个独立候选 IP，开始进行地毯式压力测试...${NC}"
    return 0
}

test_and_sort() {
    echo -e "${YELLOW}本地稳定性多维评测中（零丢包 & 极低抖动优先）...${NC}"
    echo "--------------------------------------------------------------------------------"
    
    result_file=$(mktemp)
    local count=0
    
    while IFS='|' read -r ip isp; do
        [ -z "$ip" ] && continue
        ((count++))
        [ -z "$isp" ] && isp="通用"
        
        echo -ne "正在评估 [${count}] IP: ${ip} (${isp})...\r"

        # 8包高频连续探测
        local ping_output
        ping_output=$(ping -c 8 -i 0.2 -W 2 "$ip" 2>/dev/null)
        
        # 1. 严格过滤丢包：只要丢包率大于 0%，直接判定不稳定，淘汰
        local loss_rate=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)')
        if [ -z "$loss_rate" ] || [ "$loss_rate" -ne 0 ]; then
            continue
        fi

        # 2. 提取延迟波动
        local rtt_stats=$(echo "$ping_output" | tail -n 1)
        local min_ping=$(echo "$rtt_stats" | awk -F '/' '{print $4}' | awk '{print $NF}')
        local avg_ping=$(echo "$rtt_stats" | awk -F '/' '{print $5}')
        local max_ping=$(echo "$rtt_stats" | awk -F '/' '{print $6}')
        
        # 3. 严格过滤抖动：最大与最小延迟差值如果超过 30ms，直接淘汰
        local jitter=$(echo "$max_ping - $min_ping" | bc 2>/dev/null)
        if (( $(echo "$jitter > 30" | bc -l) )); then
            continue
        fi

        # 4. 稳定性过关，启动真实下载采样 (下载5MB测速块，限时2秒快速掐断)
        local speed_raw
        speed_raw=$(curl -so /dev/null -w "%{speed_download}" --resolve speed.cloudflare.com:443:"$ip" https://speed.cloudflare.com/__down?bytes=5000000 --max-time 2.0 2>/dev/null)
        
        local speed_mb=$(echo "scale=2; $speed_raw / 1048576" | bc 2>/dev/null)
        [ -z "$speed_mb" ] && speed_mb="0.00"

        # 记录数据：原始速度|MB速度|平均延迟|抖动值|IP|线路
        echo "${speed_raw}|${speed_mb}|${avg_ping}|${jitter}|${ip}|${isp}" >> "$result_file"
        
    done < "$raw_data_file"

    echo -e "\n${GREEN}地毯式实测结束！正在为你清点最优结果...${NC}"
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " 聚合 IPv4 全量极致稳定测速器"
    echo -e "==================================================${NC}"
    echo ""

    get_optimized_ips || exit 1
    test_and_sort
    
    echo "---"
    echo -e "${GREEN}【全量初筛：100% 零丢包 + 低抖动】且【本地实测网速最高】的前 10 个黄金 IP：${NC}"
    echo "---"

    if [ ! -s "$result_file" ]; then
        echo -e "${RED}当前网络环境下，没有候选 IP 能完美通过 0% 丢包和低抖动测试。建议稍后重试。${NC}"
        rm -f "$raw_data_file" "$result_file"
        exit 1
    fi

    local final_count=0
    # 按照实际测出来的 speed_raw (字节/秒) 逆序数字排序
    while IFS='|' read -r raw_sp mb_sp avg_p jit ip isp; do
        ((final_count++))
        printf "${GREEN}[%02d]${NC} %-18s | %-6s | 本地速度: %-10s | 平均延迟: %-6s ms | 抖动: %s ms\n" \
            "$final_count" "$ip" "$isp" "${mb_sp} MB/s" "$avg_p" "$jit"
        
        [ "$final_count" -eq 10 ] && break
    done < <(sort -t'|' -k1,1rn "$result_file")

    rm -f "$raw_data_file" "$result_file"
    echo "---"
}

check_deps
main
