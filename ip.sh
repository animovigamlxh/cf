#!/bin/bash

INSTALL_PATH="/usr/local/bin/cfy_ip"

if [ "$0" != "$INSTALL_PATH" ]; then
    echo "正在安装 [cfy 多源本地优选测速器]..."

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
    local tmp_source1=$(mktemp)
    local tmp_source2=$(mktemp)
    trap 'rm -f "$tmp_source1" "$tmp_source2"' RETURN

    echo -e "${YELLOW}正在从多个源获取候选 IPv4 列表...${NC}"
    
    # ---------------- 抓取源 1 (wetest.vip) ----------------
    echo -e "  -> 正在读取 wetest.vip 节点网..."
    local html_content=$(curl -s --connect-timeout 10 "$url_source1")
    if [ -n "$html_content" ]; then 
        local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
        local ips1=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
        local isps1=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
        paste -d'|' <(echo "$ips1") <(echo "$isps1") > "$tmp_source1"
    else
        echo -e "${RED}  -> [警告] 源 1 请求超时或失败${NC}"
    fi

    # ---------------- 抓取源 2 (GitHub ymyuuu) ----------------
    echo -e "  -> 正在读取 GitHub (ymyuuu/IPDB)..."
    local github_content=$(curl -s --connect-timeout 10 "$url_source2")
    if [ -n "$github_content" ]; then
        # 该源格式多为 "IP#线路" 或 "IP 线路"，统一清洗转换为 IP|线路 格式
        echo "$github_content" | sed 's/[#, ]/|/g' | grep -E '^[0-9]' > "$tmp_source2"
    else
        echo -e "${RED}  -> [警告] 源 2 请求超时或失败${NC}"
    fi

    # ---------------- 合并与去重 ----------------
    # 优先根据 IP 去重，保留组合
    cat "$tmp_source1" "$tmp_source2" | awk -F'|' '!seen[$1]++ && $1!="" {print $1"|"$2}' > "$raw_data_file"

    local total_ips=$(wc -l < "$raw_data_file")
    if [ "$total_ips" -eq 0 ]; then 
        echo -e "${RED}❌ 所有源均获取失败，或未解析出任何候选 IP 地址。${NC}"
        return 1
    fi

    echo -e "${GREEN}成功合并并去重，共获得 $total_ips 个候选 IP，准备开始本地实测。${NC}"
    return 0
}

test_and_sort() {
    echo -e "${YELLOW}开始本地真实性能测试（正在为您探测本地下载速度与延迟）...${NC}"
    echo "----------------------------------------------------------------------"
    
    result_file=$(mktemp)
    local count=0
    
    while IFS='|' read -r ip isp; do
        [ -z "$ip" ] && continue
        ((count++))
        
        # 默认未知线路处理
        [ -z "$isp" ] && isp="未知"
        
        echo -ne "正在测试 [第 ${count} 个] IP: ${ip} (${isp})...\r"

        # 1. 本地 Ping 延迟测试 (发3个包，超时2秒)
        local ping_res
        if ping -c 1 -W 1 127.0.0.1 &>/dev/null; then
            ping_res=$(ping -c 3 -W 2 "$ip" 2>/dev/null | tail -n 1 | awk -F '/' '{print $5}')
        else
            ping_res=$(ping -c 3 -t 2 "$ip" 2>/dev/null | tail -n 1 | awk -F '/' '{print $5}')
        fi
        
        # 如果 ping 不通，跳过，不纳入最终优选
        if [ -z "$ping_res" ]; then
            continue
        fi

        # 2. 本地下载测速 (利用 Cloudflare 官方 10MB 测速文件，限时 2.5 秒快速掐断)
        local speed_raw
        speed_raw=$(curl -so /dev/null -w "%{speed_download}" --resolve speed.cloudflare.com:443:"$ip" https://speed.cloudflare.com/__down?bytes=10000000 --max-time 2.5 2>/dev/null)
        
        # 转换为 MB/s
        local speed_mb
        speed_mb=$(echo "scale=2; $speed_raw / 1048576" | bc 2>/dev/null)
        [ -z "$speed_mb" ] && speed_mb="0.00"

        # 写入临时文件：速度字节数|速度MB|延迟|IP|线路
        echo "${speed_raw}|${speed_mb}|${ping_res}|${ip}|${isp}" >> "$result_file"
        
    done < "$raw_data_file"

    echo -e "\n${GREEN}本地实测完成！正在生成最快的前 10 个 IP...${NC}"
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " 聚合 IPv4 本地真实测速器 (多源版)"
    echo -e "==================================================${NC}"
    echo ""

    get_optimized_ips || exit 1
    test_and_sort
    
    echo "---"
    echo -e "${GREEN}根据您本地【真实下载速度】由高到低排序，前 10 个最优 IP：${NC}"
    echo "---"

    local final_count=0
    # 按第一列 speed_raw 字节数进行逆序数字排序 (sort -rn)
    while IFS='|' read -r raw_sp mb_sp ping ip isp; do
        ((final_count++))
        printf "${GREEN}[%02d]${NC} %-18s | %-6s | 本地速度: %-10s | 本地延迟: %s ms\n" \
            "$final_count" "$ip" "$isp" "${mb_sp} MB/s" "$ping"
        
        [ "$final_count" -eq 10 ] && break
    done < <(sort -t'|' -k1,1rn "$result_file")

    # 清理临时文件
    rm -f "$raw_data_file" "$result_file"
    echo "---"
}

check_deps
main
