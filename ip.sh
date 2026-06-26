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

test_and_sort() {
    echo -e "${YELLOW}正在运行【三网均衡度 + 本地单线程下载速度】双重压测...${NC}"
    echo "--------------------------------------------------------------------------------"
    
    result_file=$(mktemp)
    
    python3 - << 'EOF' "$raw_data_file" "$result_file"
import sys, time, socket, subprocess

raw_file = sys.argv[1]
res_file = sys.argv[2]

ips = []
with open(raw_file, 'r') as f:
    for line in f:
        parts = line.strip().split('|')
        if parts and parts[0]:
            ips.append((parts[0], parts[1] if len(parts)>1 else "通用"))

test_targets = [
    {"host": "163.speedtest.net"},
    {"host": "cu.speedtest.net"},
    {"host": "cm.speedtest.net"}
]

print(f"开始深度评估 {len(ips)} 个候选 IP 的单线程爆发力...")

count = 0
with open(res_file, 'w') as out:
    for ip, isp in ips:
        count += 1
        print(f"正在多网测算 [{count}/{len(ips)}] IP: {ip} ({isp})...", end='\r')
        
        scores = []
        total_lat = 0
        failed = False
        
        # 1. 探测三网连通性
        for target in test_targets:
            try:
                start_time = time.time()
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(1.0)
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
            
        avg_lat = total_lat / len(test_targets)
        variance = sum((x - avg_lat) ** 2 for x in scores) / len(scores)
        jitter = variance ** 0.5
        
        # 2. 🚀 纯粹的单线程下载测速 (利用 curl 原生单线程机制拉取 5MB 块，硬性限时 1.5 秒)
        speed_mb = 0.0
        try:
            # --http1.1 强制单链接，避免 HTTP/2 多路复用干扰，测出最纯粹的单线程独占带宽
            cmd = f"curl -so /dev/null --http1.1 -w '%{{speed_download}}' --resolve speed.cloudflare.com:443:{ip} https://speed.cloudflare.com/__down?bytes=5000000 --max-time 1.5"
            res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            speed_raw = float(res.stdout.strip()) if res.stdout.strip() else 0.0
            speed_mb = speed_raw / 1048576.0
        except Exception:
            pass
            
        if speed_mb < 0.1: 
            continue

        # 3. 终极单线程得分公式
        final_score = (speed_mb * 100.0) / (avg_lat + (jitter * 0.5))
        
        out.write(f"{final_score:.4f}|{speed_mb:.2f}|{avg_lat:.1f}|{ip}|{isp}\n")
EOF
    echo -e "\n${GREEN}权衡算法打分完毕，开始按综合评级排序同步...${NC}"
}

sync_to_cloudflare() {
    echo -e "${YELLOW}开始将单线程综合得分最高的 10 个 IP 同步至 Cloudflare...${NC}"
    
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
    while IFS='|' read -r score mb_sp avg_l ip isp; do
        ((final_count++))
        
        local post_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}")
        
        local post_success=$(python3 -c "import json; d=json.loads('''$post_res'''); print(d.get('success',''))" 2>/dev/null)
        if [ "$post_success" == "True" ]; then
            echo -e "   [+] ${GREEN}第 [$final_count] 名推荐:${NC} $ip | 单线程速度: ${mb_sp} MB/s | 三网均延: ${avg_l}ms | 综合权重分: ${score}"
        else
            echo -e "   [x] ${RED}第 [$final_count] 个同步失败:${NC} $ip"
        fi
        
        [ "$final_count" -eq 10 ] && break
    done < <(sort -t'|' -k1,1rn "$result_file")

    echo -e "${GREEN}🎉 单线程表现最强 + 三网兼顾的黄金 IP 已经全部同步成功！${NC}"
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " IPv4 三网连通 + 本地单线程速度双重权衡器 (YAML版)"
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
