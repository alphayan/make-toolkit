#!/bin/bash
# make-toolkit 安装器主体逻辑。仅供 build-installer.sh 内联进 install.sh。
# 依赖:ui.sh(UI 原语)、common.sh(MTK_GO_TOOLS / MTK_SYS_TOOLS)。
# 不进 scripts/、不 vendor 给用户。

# 记录缺失工具,供结果摘要复用。
MTK_MISSING=()

# 针对当前系统回显一条安装命令(brew / apt / dnf / pacman)。
mtk_pkg_hint() {
    local pkg="$1"
    case "$(uname -s 2>/dev/null)" in
        Darwin) printf 'brew install %s' "$pkg" ;;
        Linux)
            if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$pkg"
            elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$pkg"
            elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm %s' "$pkg"
            else printf '用你的包管理器安装 %s' "$pkg"; fi ;;
        *) printf '安装 %s' "$pkg" ;;
    esac
}

# 装前自检:只报告,不安装。
mtk_doctor() {
    ui_section "环境自检"
    local t entry bin mod ver desc brewhint opt hint
    # 必需
    for t in go make; do
        if command -v "$t" >/dev/null 2>&1; then ui_success "$t 已安装"
        else ui_error "$t 缺失(必需,装了工具链才有用)"; MTK_MISSING+=("$t"); fi
    done
    # Go 系:缺了 make 时会自动 go install 兜底
    for entry in "${MTK_GO_TOOLS[@]}"; do
        IFS='|' read -r bin mod ver desc <<<"$entry"
        if command -v "$bin" >/dev/null 2>&1; then ui_success "$bin 已安装($desc)"
        else
            ui_warn "$bin 缺失($desc)— make 时会自动安装,或手动: go install ${mod}@${ver}"
            MTK_MISSING+=("$bin")
        fi
    done
    # 系统系:给平台相关命令
    for entry in "${MTK_SYS_TOOLS[@]}"; do
        IFS='|' read -r bin brewhint opt desc <<<"$entry"
        if command -v "$bin" >/dev/null 2>&1; then ui_success "$bin 已安装($desc)"
        else
            hint="$(mtk_pkg_hint "$bin")"
            if [[ "$opt" == "yes" ]]; then ui_info "$bin 未安装(可选,$desc)— $hint"
            else ui_warn "$bin 缺失($desc)— $hint(或 Docker 回退)"; fi
            MTK_MISSING+=("$bin")
        fi
    done
}

# 安装计划面板(纯展示,随后直接执行)。
mtk_show_plan() {
    # $1 target  $2 dest  $3 vendor_subdir
    ui_section "安装计划"
    {
        ui_kv "目标项目" "$1"
        ui_kv "工具链目录" "$2"
        ui_kv "将拷贝" "quality.mk, scripts/*.sh (含 ui.sh)"
        ui_kv "Makefile" "接入 include ${3}/quality.mk(幂等)"
        ui_kv ".gitignore" "追加 coverage_results/ 和 .build-cache/"
    } | ui_panel
}

# 幂等接入 Makefile。
mtk_link_makefile() {
    local target="$1" vendor_subdir="$2"
    local mk="$target/Makefile"
    local include_line="include ${vendor_subdir}/quality.mk"
    if [[ ! -f "$mk" ]]; then
        {
            echo "# >>> make-toolkit >>>"
            echo "# 留空则自动发现 go.mod;多模块可显式声明,例如:"
            echo "# GO_MODULES := svc-a svc-b"
            echo "$include_line"
            echo "# <<< make-toolkit <<<"
        } > "$mk"
        ui_success "已创建 Makefile 并接入工具链"
    elif grep -qF "$include_line" "$mk"; then
        ui_info "Makefile 已包含 include(脚本已刷新),跳过接线"
    else
        {
            echo ""
            echo "# >>> make-toolkit >>>"
            echo "$include_line"
            echo "# <<< make-toolkit <<<"
        } >> "$mk"
        ui_success "已向现有 Makefile 追加 include"
    fi
}

# 幂等补 .gitignore。
mtk_update_gitignore() {
    local target="$1"
    local gi="$target/.gitignore" pat
    for pat in "coverage_results/" ".build-cache/"; do
        if [[ ! -f "$gi" ]] || ! grep -qxF "$pat" "$gi" 2>/dev/null; then
            echo "$pat" >> "$gi"
        fi
    done
    ui_success ".gitignore 已更新"
}

# 结果面板 + 下一步。
mtk_show_result() {
    local target="$1"
    ui_section "完成"
    {
        ui_kv "已安装到" "$target"
        if [[ ${#MTK_MISSING[@]} -gt 0 ]]; then
            ui_kv "仍缺工具" "${MTK_MISSING[*]}"
        fi
        ui_kv "下一步" "cd \"$target\" && make tk-help"
    } | ui_panel
    ui_success "安装完成"
}
