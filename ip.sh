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
    for cmd in curl grep sed mktemp paste; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到. 请先安装它.${NC}"
            exit 1
        fi
    done
}

get_optimized_ips() {
    local url_v4="https://www.wetest.vip/page/cloudflare/address_v4.html"
    
    echo -e "${YELLOW}正在从远端获取最新 IPv4 优选数据...${NC}"
    
    local paired_data_file
    paired_data_file=$(mktemp)
    trap 'rm -f "$paired_data_file"' EXIT

    local html_content=$(curl -s "$url_v4")
    if [ -z "$html_content" ]; then 
        echo -e "${RED}❌ 获取 IPv4 列表失败，请检查网络！${NC}"
        return 1
    fi
    
    # 清洗 HTML 行
    local table_rows=$(echo "$html_content" | tr -d '\n\r' | sed 's/<tr>/\n&/g' | grep '^<tr>')
    
    # 提取 优选地址、线路名称、下载速度、平均延迟
    local ips=$(echo "$table_rows" | sed -n 's/.*data-label="优选地址">\([^<]*\)<.*/\1/p')
    local isps=$(echo "$table_rows" | sed -n 's/.*data-label="线路名称">\([^<]*\)<.*/\1/p')
    local speeds=$(echo "$table_rows" | sed -n 's/.*data-label="下载速度">\([^<]*\)<.*/\1/p')
    local pings=$(echo "$table_rows" | sed -n 's/.*data-label="平均延迟">\([^<]*\)<.*/\1/p')
    
    # 组合数据，用 '|' 作为临时分隔符防止线路或速度带空格导致解析错位
    paste -d'|' <(echo "$ips") <(echo "$isps") <(echo "$speeds") <(echo "$pings") > "$paired_data_file"

    if ! [ -s "$paired_data_file" ]; then 
        echo -e "${RED}无法解析出任何优选 IP 地址.${NC}"
        return 1
    fi

    declare -g -a ip_list isp_list speed_list ping_list
    
    # 按原网页的最优顺序读取（去除了 shuf 随机打乱）
    while IFS='|' read -r ip isp speed ping; do
        if [ -n "$ip" ]; then
            ip_list+=("$ip")
            isp_list+=("$isp")
            speed_list+=("$speed")
            ping_list+=("$ping")
        fi
    done < "$paired_data_file"

    if [ ${#ip_list[@]} -eq 0 ]; then 
        echo -e "${RED}解析成功, 但未找到任何有效的 IP 数据.${NC}"
        return 1
    fi
    
    return 0
}

main() {
    echo -e "${GREEN}=================================================="
    echo -e " 优质 IPv4 提取器 (精选前10个)"
    echo -e "==================================================${NC}"
    echo ""

    get_optimized_ips || exit 1

    local total=${#ip_list[@]}
    local count=10
    if [ "$total" -lt 10 ]; then
        count=$total
    fi

    echo "---"
    echo -e "${GREEN}成功获取最新数据，已为您筛选出速度前 $count 的最优 IPv4：${NC}"
    echo "---"

    # 格式化打印：IP、线路、速度、延迟
    for ((i=0; i<count; i++)); do
        printf "${GREEN}[%02d]${NC} %-18s | %-6s | 速度: %-10s | 延迟: %s\n" \
            "$((i+1))" "${ip_list[$i]}" "${isp_list[$i]}" "${speed_list[$i]}" "${ping_list[$i]}"
    done
    
    echo "---"
}

check_deps
main
