#!/bin/bash

INSTALL_PATH="/usr/local/bin/cfy_ip"

if [ "$0" != "$INSTALL_PATH" ]; then
    echo "正在安装 [cfy 优选 IP 提取器]..."

    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 安装需要管理员权限。请使用 'curl ... | sudo bash' 或 'sudo bash <(curl ...)' 命令来运行。"
        exit 1
    fi
    
    echo "正在将脚本写入到 $INSTALL_PATH..."
    
    # 智能判断执行模式
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
    for cmd in curl grep sed mktemp shuf paste; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它.${NC}"
            exit 1
        fi
    done
}

get_optimized_ips() {
    local url_v4="https://www.wetest.vip/page/cloudflare/address_v4.html"
    local url_v6="https://www.wetest.vip/page/cloudfront/address_v6.html"
    
    echo -e "${YELLOW}正在获取优选 IP (IPv4 & IPv6)...${NC}"
    
    local paired_data_file
    paired_data_file=$(mktemp)
    trap 'rm -f "$paired_data_file"' EXIT

    parse_url() {
        local url="$1"; local type_desc="$2"
        echo -e "  -> 正在获取 ${type_desc} 列表..."
        local html_content=$(curl -s "$url")
        if [ -z "$html_content" ]; then echo -e "${RED}  -> 获取 ${type_desc} 列表失败!${NC}"; return; fi
        local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
        local ips=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
        local isps=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
        paste -d' ' <(echo "$ips") <(echo "$isps") >> "$paired_data_file"
    }

    parse_url "$url_v4" "IPv4"
    parse_url "$url_v6" "IPv6"

    if ! [ -s "$paired_data_file" ]; then 
        echo -e "${RED}无法从任何来源解析出优选 IP 地址.${NC}"
        return 1
    fi

    declare -g -a ip_list isp_list
    local shuffled_pairs
    
    # 随机打乱列表并过滤空行
    mapfile -t shuffled_pairs < <(shuf "$paired_data_file" | grep -v '^ *$')
    
    for pair in "${shuffled_pairs[@]}"; do
        local ip=$(echo "$pair" | cut -d' ' -f1)
        local isp=$(echo "$pair" | cut -d' ' -f2-)
        if [ -n "$ip" ]; then
            ip_list+=("$ip")
            isp_list+=("$isp")
        fi
    done

    if [ ${#ip_list[@]} -eq 0 ]; then 
        echo -e "${RED}解析成功, 但未找到任何有效的 IP 地址.${NC}"
        return 1
    fi
    
    return 0
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " 优选 IP 提取器 (仅保留前10个)"
    echo -e "==================================================${NC}"
    echo ""

    get_optimized_ips || exit 1

    # 获取总数和需要输出的数量（最多10个）
    local total=${#ip_list[@]}
    local count=10
    if [ "$total" -lt 10 ]; then
        count=$total
    fi

    echo "---"
    echo -e "${GREEN}成功合并获取并随机打乱了 $total 个 IP，以下是前 $count 个优选 IP：${NC}"
    echo "---"

    for ((i=0; i<count; i++)); do
        printf "${GREEN}[%02d]${NC} %-30s (%s)\n" "$((i+1))" "${ip_list[$i]}" "${isp_list[$i]}"
    done
    
    echo "---"
}

check_deps
main
