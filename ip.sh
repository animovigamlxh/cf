#!/bin/bash

INSTALL_PATH="/usr/local/bin/cfy_ip"
# 统一修改为全系统最稳妥的全局配置路径
CONFIG_FILE="/etc/cfy_config.json"

if [ "$0" != "$INSTALL_PATH" ]; then
    echo "正在安装 [cfy 极致稳定+CF解析同步器 (安全配置文件版)]..."

    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 安装需要管理员权限。请使用 'sudo bash' 运行。"
        exit 1
    fi
    
    echo "正在将脚本写入到 $INSTALL_PATH..."
    if [[ "$(basename "$0")" == "bash" || "$(basename "$0")" == "sh" || "$(basename "$0")" == "-bash" ]]; then
        if ! cat /proc/self/fd/0 > "$INSTALL_PATH"; then echo "❌ 写入失败"; exit 1; fi
    else
        if ! cp "$0" "$INSTALL_PATH"; then echo "❌ 复制失败"; exit 1; fi
    fi

    if [ $? -eq 0 ]; then
        chmod +x "$INSTALL_PATH"
        echo "✅ 安装成功! 您现在可以随时运行 'cfy_ip' 命令。"
        echo "---"
        echo "首次运行..."
        exec "$INSTALL_PATH"
    else
        exit 1
    fi
    exit 0
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_deps() {
    for cmd in curl grep sed mktemp paste ping bc awk sort uniq jq; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它(如 apt/yum install jq bc).${NC}"
            exit 1
        fi
    done
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 未找到本地配置文件: $CONFIG_FILE${NC}"
        echo -e "${YELLOW}请先在 VPS 上创建该文件并填入 Cloudflare 密钥，命令如下：${NC}"
        echo -e "${GREEN}cat << 'EOF' > /etc/cfy_config.json"
        echo -e '{\n    "CF_TOKEN": "您的_Token",\n    "CF_ZONE_ID": "您的_Zone_ID",\n    "CF_RECORD_NAME": "cf.yylxjichang-online.top"\n}'
        echo -e "EOF\nchmod 600 /etc/cfy_config.json${NC}"
        exit 1
    fi

    CF_TOKEN=$(jq -r '.CF_TOKEN // empty' "$CONFIG_FILE")
    CF_ZONE_ID=$(jq -r '.CF_ZONE_ID // empty' "$CONFIG_FILE")
    CF_RECORD_NAME=$(jq -r '.CF_RECORD_NAME // "cf.yylxjichang-online.top"' "$CONFIG_FILE")

    if [ -z "$CF_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ "$CF_TOKEN" == "你的_Cloudflare_API_Token" ]; then
        echo -e "${RED}❌ 配置文件中的 CF_TOKEN 或 CF_ZONE_ID 无效，请检查 $CONFIG_FILE${NC}"
        exit 1
    fi
}

get_optimized_ips() {
    local url_source1="https://www.wetest.vip/page/cloudflare/address_v4.html"
    local url_source2="https://raw.githubusercontent.com/ymyuuu/IPDB/refs/heads/main/BestCF/bestcfv4.txt"
    
    raw_data_file=$(mktemp)
    local tmp_all_source=$(mktemp)
    trap 'rm -f "$tmp_all_source"' RETURN

    echo -e "${YELLOW}正在拉取全部源数据 (全量无删减)...${NC}"
    
    local html_content=$(curl -s --connect-timeout 8 "$url_source1")
    if [ -n "$html_content" ]; then 
        local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
        local ips1=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
        local isps1=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
        paste -d'|' <(echo "$ips1") <(echo "$isps1") >> "$tmp_all_source"
    fi

    local github_content=$(curl -s --connect-timeout 8 "$url_source2")
    if [ -n "$github_content" ]; then
        echo "$github_content" | sed 's/[#, ]/|/g' >> "$tmp_all_source"
    fi

    awk -F'|' '{
        if ($1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
            if (!seen[$1]++) { print $1"|"$2 }
        }
    }' "$tmp_all_source" > "$raw_data_file"

    local total_ips=$(wc -l < "$raw_data_file")
    if [ "$total_ips" -eq 0 ]; then 
        echo -e "${RED}❌ 所有源均获取失败，请检查网络。${NC}"
        return 1
    fi

    echo -e "${GREEN}全量提取成功！已捕获 $total_ips 个独立候选 IP，开始性能压测...${NC}"
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

        local ping_output=$(ping -c 8 -i 0.2 -W 2 "$ip" 2>/dev/null)
        
        local loss_rate=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)')
        if [ -z "$loss_rate" ] || [ "$loss_rate" -ne 0 ]; then continue; fi

        local rtt_stats=$(echo "$ping_output" | tail -n 1)
        local min_ping=$(echo "$rtt_stats" | awk -F '/' '{print $4}' | awk '{print $NF}')
        local avg_ping=$(echo "$rtt_stats" | awk -F '/' '{print $5}')
        local max_ping=$(echo "$rtt_stats" | awk -F '/' '{print $6}')
        
        local jitter=$(echo "$max_ping - $min_ping" | bc 2>/dev/null)
        if (( $(echo "$jitter > 30" | bc -l) )); then continue; fi

        local speed_raw=$(curl -so /dev/null -w "%{speed_download}" --resolve speed.cloudflare.com:443:"$ip" https://speed.cloudflare.com/__down?bytes=5000000 --max-time 2.0 2>/dev/null)
        local speed_mb=$(echo "scale=2; $speed_raw / 1048576" | bc 2>/dev/null)
        [ -z "$speed_mb" ] && speed_mb="0.00"

        echo "${speed_raw}|${speed_mb}|${avg_ping}|${jitter}|${ip}|${isp}" >> "$result_file"
    done < "$raw_data_file"
}

sync_to_cloudflare() {
    echo -e "${YELLOW}开始将优选出的 10 个 IP 同步至 Cloudflare...${NC}"
    
    echo " -> 正在获取旧解析记录列表..."
    local records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json")

    if [ "$(echo "$records" | jq -r '.success')" != "true" ]; then
        echo -e "${RED}❌ 读取 Cloudflare 失败，请检查本地 JSON 配置中的 Token 或 Zone ID 是否正确。${NC}"
        return 1
    fi

    local record_ids=$(echo "$records" | jq -r '.result[].id')
    for id in $record_ids; do
        echo "   [-] 正在清理旧记录 ID: $id"
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null
    done

    echo " -> 正在推送最新前 10 个黄金 IP 至 Cloudflare..."
    local final_count=0
    while IFS='|' read -r raw_sp mb_sp avg_p jit ip isp; do
        ((final_count++))
        
        local post_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}")
        
        if [ "$(echo "$post_res" | jq -r '.success')" == "true" ]; then
            echo -e "   [+] ${GREEN}第 [$final_count] 个同步成功:${NC} $ip ($isp) | 速度: $mb_sp MB/s"
        else
            echo -e "   [x] ${RED}第 [$final_count] 个同步失败:${NC} $ip"
        fi
        
        [ "$final_count" -eq 10 ] && break
    done < <(sort -t'|' -k1,1rn "$result_file")

    echo -e "${GREEN}🎉 Cloudflare DNS 数据同步大功告成！${NC}"
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " IPv4 全量极致稳定测速器 + CF DNS 自动同步 (安全版)"
    echo -e "==================================================${NC}"
    echo ""

    load_config
    get_optimized_ips || exit 1
    test_and_sort
    
    if [ ! -s "$result_file" ]; then
        echo -e "${RED}当前没有符合条件的 IP。${NC}"
        rm -f "$raw_data_file" "$result_file"
        exit 1
    fi

    echo "--------------------------------------------------------------------------------"
    sync_to_cloudflare
    
    rm -f "$raw_data_file" "$result_file"
    echo "---"
}

check_deps
main
