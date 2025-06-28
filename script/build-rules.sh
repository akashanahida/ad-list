#!/bin/bash

# DNS 规则处理脚本
# 功能：下载、合并、去重和转换各种广告拦截规则

set -e  # 遇到错误时退出

# ====== 配置变量 ======
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DNS_FILE="dns.txt"
DOMAIN_FILE="domain.txt" 
DOMAINSET_FILE="domainset.txt"
OISD_FILE="oisd.txt"
OUTPUT_FILE="dns-output.txt"
MIHOMO_FILE="mihomo.mrs"
SINGBOX_FILE="adfilter-singbox.srs"

# 规则源URL列表
RULE_URLS=(
    "https://raw.githubusercontent.com/Cats-Team/AdRules/main/dns.txt"
    "https://big.oisd.nl"
    # "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt"
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
    rm -f ./*.txt sing-box* mihomo-linux-amd64-* version.txt
    find . -name "sing-box-*" -type d -exec rm -rf {} + 2>/dev/null || true
}

# 错误处理
trap cleanup_temp_files EXIT

# ====== 主要功能函数 ======

# 下载基础规则文件
download_base_rules() {
    log_info "开始下载基础规则文件..."
    
    # 清空并初始化 DNS 文件
    > "$DNS_FILE"
    
    # 下载基础规则
    for url in "${RULE_URLS[@]}"; do
        log_info "下载规则: $url"
        if curl -sSL --connect-timeout 10 --max-time 60 "$url" >> "$DNS_FILE"; then
            log_info "成功下载: $url"
        else
            log_error "下载失败: $url"
        fi
    done
}

# 处理 Surge 规则
process_surge_rules() {
    log_info "处理 Surge 规则..."
    
    # 处理第一个 Surge 规则源
    log_info "处理 HotKids/Rules Surge 规则..."
    curl -s --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/HotKids/Rules/refs/heads/master/Surge/RULE-SET/AD.list" \
        | grep -E '^(DOMAIN-SUFFIX|DOMAIN),' \
        | cut -d',' -f2 \
        | sed 's/^[[:space:]]*//' \
        | sort -u >> "$DNS_FILE"
    
    # 处理第二个 Surge 规则源
    log_info "处理 Adblock4limbo Surge 规则..."
    curl -skL --connect-timeout 10 --max-time 60 \
        "https://github.com/limbopro/Adblock4limbo/raw/main/rule/Surge/Adblock4limbo_surge.list" \
        | sed 's/,reject$//g' \
        | grep -E '^(DOMAIN-SUFFIX|DOMAIN),' \
        | cut -d',' -f2 \
        | grep -vE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
        | sed 's/^[[:space:]]*//' >> "$DNS_FILE"
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
    if [[ -f "sort.py" ]]; then
        log_info "使用 Python 脚本进行排序和去重..."
        python sort.py "$DNS_FILE"
    else
        log_info "使用系统命令进行排序和去重..."
        sort -u "$DNS_FILE" -o "$DNS_FILE"
    fi
}

# 下载白名单
download_whitelist() {
    log_info "下载 OISD 白名单..."
    
    curl -s --connect-timeout 10 --max-time 60 "https://oisd.nl/excludes.php" \
        | grep -o '<a href=[^>]*>[^<]*' \
        | sed 's/.*>//' \
        | sort -u > "$OISD_FILE"
}

# 使用 hostlist-compiler 优化规则
optimize_with_hostlist_compiler() {
    log_info "使用 hostlist-compiler 优化规则..."
    
    if command -v hostlist-compiler >/dev/null 2>&1; then
        if [[ -f "dns.json" ]]; then
            hostlist-compiler -c dns.json -o "$OUTPUT_FILE"
            
            # 提取仅包含黑名单规则的行
            grep -v '\[' "$OUTPUT_FILE" > "$DNS_FILE"
            
            # 再次排序规则
            if [[ -f "sort.py" ]]; then
                python sort.py "$DNS_FILE"
            else
                sort -u "$DNS_FILE" -o "$DNS_FILE"
            fi
        else
            log_info "未找到 dns.json 配置文件，跳过 hostlist-compiler 优化"
        fi
    else
        log_info "未安装 hostlist-compiler，跳过优化步骤"
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
    
    local singbox_version="1.11.11"
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
    
    # 下载版本信息
    if wget -q --timeout=30 "https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt"; then
        local version
        version=$(cat version.txt)
        local mihomo_file="mihomo-linux-amd64-${version}"
        local download_url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/${mihomo_file}.gz"
        
        log_info "下载 mihomo 版本: $version"
        if wget -q --timeout=60 "$download_url"; then
            gzip -d "${mihomo_file}.gz"
            chmod +x "$mihomo_file"
            
            # 转换规则集
            ./"$mihomo_file" convert-ruleset domain text "$DOMAINSET_FILE" "$MIHOMO_FILE"
            
            # 移动生成的规则文件
            mv "$DNS_FILE" "$MIHOMO_FILE" ../rules/
            log_info "mihomo 规则文件已生成"
            
            # 清理
            rm "$mihomo_file"
        else
            log_error "下载 mihomo 失败"
        fi
    else
        log_error "获取 mihomo 版本信息失败"
    fi
}

# 更新 README 文件
update_readme() {
    log_info "更新 README 文件..."

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
    process_surge_rules
    add_custom_rules
    normalize_rules
    download_whitelist
    optimize_with_hostlist_compiler
    generate_domain_lists
    process_with_singbox
    process_with_mihomo
    update_readme
    
    log_info "DNS 规则处理完成！"
}

# 执行主函数
main "$@"
