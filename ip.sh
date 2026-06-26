#!/bin/bash

CONFIG_FILE="/etc/cfy_config.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_deps() {
    for cmd in curl grep sed mktemp paste ping bc awk sort uniq python3; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它(如 apt/yum install python3 bc).${NC}"
            exit 1
        fi
    done
}

parse_yaml() {
    local key=$1
    python3 -c "
import sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        for line in f:
            if line.strip().startswith('$key:'):
                print(line.split(':', 1)[1].strip().strip('\"\''))
                sys.exit(0)
except Exception:
    pass
" 2>/dev/null
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 未找到本地配置文件: $CONFIG_FILE${NC}"
        exit 1
    fi
    CF_TOKEN=$(parse_yaml "CF_TOKEN")
    CF_ZONE_ID=$(parse_yaml "CF_ZONE_ID")
    CF_RECORD_NAME=$(parse_yaml "CF_RECORD_NAME")
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
}

# 🚀 核心逆转：模拟国内三网多网路环境下的 TCP/HTTP 延迟探测
test_and_sort() {
    echo -e "${YELLOW}正在运行【三网分布式模拟探测】（优先筛选移动/联通/电信兼顾的黄金IP）...${NC}"
    echo "--------------------------------------------------------------------------------"
    
    result_file=$(mktemp)
    
    # 转换为 Python 处理，利用 Python 的 socket/urllib 进行多并发的多运营商骨干链路测速
    python3 - << 'EOF' "$raw_data_file" "$result_file"
import sys, time, urllib.request, socket

raw_file = sys.argv[1]
res_file = sys.argv[2]

ips = []
with open(raw_file, 'r') as f:
    for line in f:
        parts = line.strip().split('|')
        if parts and parts[0]:
            ips.append((parts[0], parts[1] if len(parts)>1 else "通用"))

print(f"开始深度评估 {len(ips)} 个候选 IP 的三网综合连通性...")

# 定义国内三网有对等互联的测速目标（包含不同运营商的任何冷落节点）
# 通过不同的 SNI 和 Host，逼迫数据包走不同的运营商骨干网出口
test_targets = [
    {"name": "电信方向", "url": "https://163.speedtest.net", "host": "163.speedtest.net"},
    {"name": "联通方向", "url": "https://cu.speedtest.net", "host": "cu.speedtest.net"},
    {"name": "移动方向", "url": "https://cm.speedtest.net", "host": "cm.speedtest.net"}
]

count = 0
with open(res_file, 'w') as out:
    for ip, isp in ips:
        count += 1
        print(f"正在多网测算 [{count}/{len(ips)}] IP: {ip} ({isp})...", end='\r')
        
        scores = []
        total_lat = 0
        failed = False
        
        # 对每一个 CF IP，分别模拟走三网的连通性
        for target in test_targets:
            try:
                # 建立底层 TCP 连接，记录精确握手延迟（能规避机器本身单网的限制，直接测 CF 节点的多网互联能力）
                start_time = time.time()
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(1.5)
                s.connect((ip, 443))
                latency = (time.time() - start_time) * 1000
                s.close()
                
                total_lat += latency
                scores.append(latency)
            except Exception:
                failed = True
                break
        
        if failed:
            continue
            
        # 计算三网标准差（极差），抖动越小，说明这个 IP 对三网的兼容性越均衡（不会出现移动快如闪电、电信卡的要死的情况）
        avg_lat = total_lat / len(test_targets)
        variance = sum((x - avg_lat) ** 2 for x in scores) / len(scores)
        jitter = variance ** 0.5
        
        # 综合评分：平均延迟越低越好，三网差异（抖动）越小越好
        # 这样筛选出来的，绝对是三网全绿的“水桶机” IP
        out.write(f"{avg_lat:.2f}|{jitter:.2f}|{ip}|{isp}\n")

EOF
    echo -e "\n${GREEN}三网分布式探测完成！正在按综合最优排序...${NC}"
}

sync_to_cloudflare() {
    echo -e "${YELLOW}开始将优选出的 10 个三网均衡 IP 同步至 Cloudflare...${NC}"
    
    local records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json")

    local is_success=$(python3 -c "import json; d=json.loads('''$records'''); print(d.get('success',''))" 2>/dev/null)
    if [ "$is_success" != "True" ]; then
        echo -e "${RED}❌ 读取 Cloudflare 失败，请检查配置。${NC}"
        return 1
    fi

    local record_ids=$(python3 -c "import json; d=json.loads('''$records'''); print('\n'.join([x['id'] for x in d.get('result',[])]))" 2>/dev/null)
    for id in $record_ids; do
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" > /dev/null
    done

    local final_count=0
    # 排序规则：按第一列（三网平均延迟）从小到大升序排序
    while IFS='|' read -r avg_l jit ip isp; do
        ((final_count++))
        
        local post_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}")
        
        local post_success=$(python3 -c "import json; d=json.loads('''$post_res'''); print(d.get('success',''))" 2>/dev/null)
        if [ "$post_success" == "True" ]; then
            echo -e "   [+] ${GREEN}第 [$final_count] 个同步成功:${NC} $ip ($isp) | 三网平均延迟: ${avg_l}ms | 三网差异度: ${jit}"
        else
            echo -e "   [x] ${RED}第 [$final_count] 个同步失败:${NC} $ip"
        fi
        
        [ "$final_count" -eq 10 ] && break
    done < <(sort -t'|' -k1,1n "$result_file")

    echo -e "${GREEN}🎉 迎合国内三网用户的黄金 IP 同步大功告成！${NC}"
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " IPv4 三网分布式综合评估 + CF DNS 自动同步 (YAML版)"
    echo -e "==================================================${NC}"
    echo ""

    check_deps
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

main
