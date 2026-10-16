#!/bin/bash

# DNS 规则处理脚本
# 功能：下载、合并、去重和转换各种广告拦截规则

set -euo pipefail  # 遇到错误、使用未定义变量或管道中任一命令失败时退出

# ====== 配置变量 ======
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DNS_FILE="dns.txt"
DOMAIN_FILE="domain.txt" 
DOMAINSET_FILE="domainset.txt"
OISD_FILE="oisd.txt"

MIHOMO_FILE="mihomo.mrs"
SINGBOX_FILE="adfilter-singbox.srs"

# 规则源URL列表（基础规则）
RULE_URLS=(
    # Cats-Team AdRules
    "https://raw.githubusercontent.com/Cats-Team/AdRules/main/dns.txt"
    # OISD
    "https://big.oisd.nl"
    # Hagezi DNS Blocklists
    #"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.mini.txt"
    # 10007
    #"https://raw.githubusercontent.com/lingeringsound/10007_auto/master/adb.txt"
    # ShadowWhisperer - Tracking
    #"https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Tracking"
    # anti-AD - HTTPDNS 拦截规则
    #"https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/refs/heads/master/discretion/dns.txt"
    # anti-AD PCDN - P2P CDN 拦截规则
    "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/refs/heads/master/discretion/pcdn.txt"
    # Sukka 规则集 - AdGuard Home 拒绝规则
    #"https://ruleset.skk.moe/Internal/reject-adguardhome.txt"
    # ====== Surge 格式规则 ======
    # HotKids Rules - Surge 广告规则集
    "https://raw.githubusercontent.com/HotKids/Rules/refs/heads/master/Surge/RULE-SET/AD.list"
    # Adblock4limbo - limbopro 的 Surge 广告拦截规则
    "https://github.com/limbopro/Adblock4limbo/raw/main/rule/Surge/Adblock4limbo_surge.list"
)

# ====== 工具函数 ======
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

cleanup_temp_files() {
    log_info "清理临时文件..."
    rm -f ./*.txt sing-box* mihomo-linux-amd64-* version.txt remove.py dns-allowlist.txt
    find . -name "sing-box-*" -type d -exec rm -rf {} + 2>/dev/null || true
}

# 错误处理
trap cleanup_temp_files EXIT

# ====== 主要功能函数 ======

# 下载基础规则文件（使用 xargs 并发）
download_base_rules() {
    log_info "开始下载基础规则文件（并发模式）..."
    
    # 清空并初始化 DNS 文件
    > "$DNS_FILE"
    
    # 创建临时目录
    local temp_dir="temp_downloads_$$"
    mkdir -p "$temp_dir"
    
    # 使用 xargs 并发下载基础规则（最多 5 个并发）
    log_info "使用 xargs 并发下载 ${#RULE_URLS[@]} 个规则源..."
    printf '%s\n' "${RULE_URLS[@]}" | xargs -P 5 -I {} bash -c '
        url="{}"
        index=$(echo "$url" | md5sum | cut -c1-8)
        temp_file="'"$temp_dir"'/rule_$index.txt"
        echo "[INFO] $(date +"%Y-%m-%d %H:%M:%S") - 下载规则: $url"
        if curl -sSL --connect-timeout 10 --max-time 60 "$url" > "$temp_file" 2>/dev/null; then
            echo "[INFO] $(date +"%Y-%m-%d %H:%M:%S") - 成功下载: $url"
        else
            echo "[ERROR] $(date +"%Y-%m-%d %H:%M:%S") - 下载失败: $url" >&2
            rm -f "$temp_file"
        fi
    '
    
    # 合并所有成功下载的文件
    log_info "合并下载的规则文件..."
    cat "$temp_dir"/rule_*.txt >> "$DNS_FILE" 2>/dev/null || true
    
    # 下载 V2Fly 规则（单独处理，因为需要转换）
    local v2fly_url='https://raw.githubusercontent.com/v2fly/domain-list-community/release/category-ads-all.txt'
    log_info "下载 V2Fly 规则: $v2fly_url"
    
    # 下载、转换并追加（失败不退出）
    if curl -sSL --connect-timeout 60 --max-time 120 "$v2fly_url" | \
        tr -d '\r' | \
        grep -E '^(domain|full):[a-zA-Z0-9]([a-zA-Z0-9\.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}(:@ads)?$' | \
        sed -E 's/^(domain|full):([^:]+)(:@ads)?$/127.0.0.1 \2/' | \
        LC_ALL=C sort -u >> "$DNS_FILE"; then
        log_info "V2Fly 规则已追加，共 $(wc -l < "$DNS_FILE") 行"
    else
        log_error "V2Fly 规则下载失败，继续执行后续步骤"
    fi
    
    # 清理临时目录
    rm -rf "$temp_dir"
    log_info "临时文件已清理"
}

# 添加自定义规则
add_custom_rules() {
    log_info "添加自定义规则..."
    
    local custom_rules_file="../rules/myrules.txt"
    if [[ -f "$custom_rules_file" ]]; then
        cat "$custom_rules_file" >> "$DNS_FILE"
        log_info "已添加自定义规则"
    else
        log_info "未找到自定义规则文件: $custom_rules_file"
    fi
}

# 规范化和去重规则
normalize_rules() {
    log_info "规范化规则格式..."
    
    # 修复换行符，统一格式
    sed -i 's/\r//' "$DNS_FILE"
    
    # 去重并排序规则
    if [[ -f "sort.py" && -f "compressor.py" ]]; then
        log_info "使用 Python 脚本进行排序和去重..."
        python compressor.py "$DNS_FILE" -i --include-regex --include-wildcard
        python sort.py "$DNS_FILE"
    else
        log_info "使用系统命令进行排序和去重（回退方案）..."
        sort -u "$DNS_FILE" -o "$DNS_FILE"
    fi
}

# 下载并应用 DNS 白名单过滤
apply_dns_whitelist() {
    log_info "下载并应用 DNS 白名单..."
    curl -sSL -o dns-allowlist.txt "https://raw.githubusercontent.com/Cats-Team/AdRules/refs/heads/script/mod/rules/dns-allowlist.txt" || return 1
    curl -sSL -o remove.py "https://raw.githubusercontent.com/Cats-Team/AdRules/refs/heads/script/script/remove.py" || { rm -f dns-allowlist.txt; return 1; }
    python remove.py --blacklist "$DNS_FILE" --whitelist dns-allowlist.txt
    rm -f dns-allowlist.txt remove.py
    log_info "白名单过滤完成"    
}

# 下载白名单
download_whitelist() {
    log_info "下载 OISD 白名单..."
    
    curl -s --connect-timeout 10 --max-time 60 "https://oisd.nl/excludes.php" \
        | grep -o '<a href=[^>]*>[^<]*' \
        | sed 's/.*>//' \
        | sort -u \
        | sed 's/^/||/; s/$/^/' > "$OISD_FILE"
    
    # 应用白名单，排除 DNS_FILE 里的规则
    if [ -f "$DNS_FILE" ] && [ -f "$OISD_FILE" ]; then
        log_info "正在应用白名单..."
        local original_count
        original_count=$(wc -l < "$DNS_FILE")
        
        awk 'NR==FNR{whitelist[$0]=1; next} !($0 in whitelist)' "$OISD_FILE" "$DNS_FILE" > "$DNS_FILE.tmp" && mv "$DNS_FILE.tmp" "$DNS_FILE"
        
        local filtered_count
        filtered_count=$(wc -l < "$DNS_FILE")
        local excluded_count=$((original_count - filtered_count))
        log_info "白名单应用完成，排除了 $excluded_count 条规则，剩余 $filtered_count 条规则"
    fi
}

# 生成域名列表文件
generate_domain_lists() {
    log_info "生成域名列表文件..."
    
    # 生成纯域名列表
    grep -vE '(@|\*|\[)' "$DNS_FILE" \
        | grep -Po "(?<=\|\|).+(?=\^)" \
        | grep -v "\*" > "$DOMAIN_FILE"
    
    # 生成域名集合格式
    sed "s/^/\+\./g" "$DOMAIN_FILE" > "$DOMAINSET_FILE"
}

# 下载和使用 sing-box 工具
process_with_singbox() {
    log_info "处理 sing-box 规则转换..."
    
    local singbox_version="1.12.12"
    local singbox_archive="sing-box-${singbox_version}-linux-amd64.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${singbox_version}/${singbox_archive}"
    
    # 下载 sing-box
    log_info "下载 sing-box v${singbox_version}..."
    if wget -q --timeout=60 "$download_url"; then
        tar -zxf "$singbox_archive"
        mv "sing-box-${singbox_version}-linux-amd64/sing-box" sing-box
        chmod +x sing-box
        
        # 转换规则
        ./sing-box rule-set convert "$DNS_FILE" -t adguard
        
        # 移动生成的文件
        if [[ -f "dns.srs" ]]; then
            mv dns.srs "../rules/$SINGBOX_FILE"
            log_info "sing-box 规则文件已生成: ../rules/$SINGBOX_FILE"
        fi
        
        # 清理文件
        rm -rf sing-box* "sing-box-${singbox_version}-linux-amd64"*
    else
        log_error "下载 sing-box 失败"
    fi
}

# 下载和使用 mihomo 工具
process_with_mihomo() {
    log_info "处理 mihomo 规则转换..."
    
    local version="v1.19.20"
    local mihomo_file="mihomo-linux-amd64-${version}"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/${mihomo_file}.gz"
    
    log_info "下载 mihomo 版本: $version"
    if wget -q --timeout=60 "$download_url"; then
        gzip -d "${mihomo_file}.gz"
        chmod +x "$mihomo_file"
        
        # 转换规则集
        ./"$mihomo_file" convert-ruleset domain text "$DOMAINSET_FILE" "$MIHOMO_FILE"
        
        # 移动生成的规则文件
        mv "$MIHOMO_FILE" ../rules/
        log_info "mihomo 规则文件已生成"
        
        # 清理
        rm "$mihomo_file"
    else
        log_error "下载 mihomo 失败"
    fi
}


# 更新 README 文件
update_readme() {
    log_info "更新 README 文件..."
    mv "$DNS_FILE" ../rules/
    local max_tries=4
    local tries=0
    local current_dir="$PWD"

    # 查找 README.md 文件
    while [[ ! -f "README.md" && $tries -lt $max_tries ]]; do
        cd ..
        tries=$((tries + 1))
    done

    if [[ -f "README.md" ]]; then
        local rule_count
        rule_count=$(grep -vc '^!' "./rules/dns.txt" 2>/dev/null || echo "0")
        local update_time
        update_time=$(date '+%Y-%m-%d %H:%M:%S')

        # 更新 README 内容
        sed -i '8,$d' README.md
        cat <<EOF >> README.md
---
**DNS规则统计**
规则总数: $rule_count  
最后更新: $update_time
EOF
        
        # 自动选择行尾符转换工具
        if command -v dos2unix &>/dev/null; then
            dos2unix README.md >/dev/null 2>&1
            log_info "使用 dos2unix 转换行尾符"
        else
            sed -i 's/\r$//' README.md
            log_info "使用 sed 转换行尾符（dos2unix 不可用）"
        fi
        
        log_info "README.md 更新完成"
        tail -n 4 README.md
    else
        log_error "未找到 README.md（已搜索 $max_tries 层目录）"
        cd "$current_dir"
        return 1
    fi
    
    # 返回原始目录
    cd "$current_dir"
}

# ====== 主执行流程 ======
main() {
    log_info "开始执行 DNS 规则处理脚本"
    log_info "工作目录: $SCRIPT_DIR"
    
    # 切换到脚本所在目录
    cd "$SCRIPT_DIR"
    
    # 执行各个处理步骤
    download_base_rules
    add_custom_rules
    normalize_rules
    apply_dns_whitelist
    generate_domain_lists
    process_with_singbox
    process_with_mihomo
    update_readme
    
    log_info "DNS 规则处理完成！"
}

# 执行主函数
main "$@"
