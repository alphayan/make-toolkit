#!/bin/bash

# make-toolkit 公共函数库
# 提供日志、工具安装、Go 模块发现等公共功能。
# 来源：从一套多模块 Go 项目的 deploy/scripts 通用化而来。
#
# 本文件是被 source 的库,不设置 set -e——错误模式由各消费脚本自行决定
# (format-code.sh 依赖关闭 set -e 以并发收集各模块结果)。

# 加载 UI 原语(同目录)。内嵌进 install.sh 或从 stdin 执行时守卫跳过,
# 复用已就地定义的 ui_*;作为 vendor 文件时正常 source。
_MK_DIR=""
if [[ ${#BASH_SOURCE[@]} -gt 0 && -n "${BASH_SOURCE[0]:-}" ]]; then
    _MK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo .)"
fi
if [[ -n "$_MK_DIR" && -f "$_MK_DIR/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_MK_DIR/ui.sh"
    ui_init_colors
fi

# 兼容旧调用点:log_* 转调 ui_*(无色降级时输出与历史一致)。
log_info()    { ui_info "$@"; }
log_success() { ui_success "$@"; }
log_warning() { ui_warn "$@"; }
log_error()   { ui_error "$@"; }
log_step()    { ui_stage "$@"; }

# ---- golangci-lint 版本与模块路径:单一事实来源 ----
# v2 起 Go 模块路径带 /vN 主版本后缀,须按版本号推导;v1.* 沿用旧路径。
# 回退 v1:GOLANGCI_LINT_VERSION=v1.64.8(注意 v1 与 v2 的 .golangci.yml 格式不同)。
MTK_GOLANGCI_VERSION="${GOLANGCI_LINT_VERSION:-v2.12.2}"
case "$MTK_GOLANGCI_VERSION" in
    v1.*) MTK_GOLANGCI_MODULE="github.com/golangci/golangci-lint/cmd/golangci-lint" ;;
    v*.*) MTK_GOLANGCI_MODULE="github.com/golangci/golangci-lint/${MTK_GOLANGCI_VERSION%%.*}/cmd/golangci-lint" ;;
    *)    MTK_GOLANGCI_MODULE="github.com/golangci/golangci-lint/v2/cmd/golangci-lint" ;;
esac

# ---- 工具清单:单一事实来源(供 ensure_* 与安装器 doctor 共用)----
# bash 3.2 无关联数组,用 "字段|字段" 字符串数组。
# MTK_GO_TOOLS 每项:binary|module|version|desc
# shellcheck disable=SC2034  # 由内联进 install.sh 的 installer/body.sh 消费
MTK_GO_TOOLS=(
    "gofumpt|mvdan.cc/gofumpt|latest|格式化"
    "goimports|golang.org/x/tools/cmd/goimports|latest|整理导入"
    "golangci-lint|${MTK_GOLANGCI_MODULE}|${MTK_GOLANGCI_VERSION}|质量检查(含 staticcheck/ineffassign)"
    "govulncheck|golang.org/x/vuln/cmd/govulncheck|latest|漏洞扫描"
)
# MTK_SYS_TOOLS 每项:binary|brew_install_hint|optional(yes/no)|desc
# shellcheck disable=SC2034  # 同上,供 installer/body.sh 的 doctor 使用
MTK_SYS_TOOLS=(
    "trivy|brew install trivy|no|整仓/前端漏洞(可 docker 回退)"
    "cloc|brew install cloc|yes|代码行数统计"
)

# 向 PATH 追加目录（若未包含）
add_path_if_missing() {
    local dir="$1"
    if [[ -n "$dir" && -d "$dir" ]]; then
        case ":$PATH:" in
            *":$dir:"*) ;;
            *) export PATH="$PATH:$dir" ;;
        esac
    fi
}

# 判断数组中是否已包含指定元素（兼容旧版 Bash）
contains_item() {
    local item="$1"
    shift
    local element
    for element in "$@"; do
        if [[ "$element" == "$item" ]]; then
            return 0
        fi
    done
    return 1
}

# 确保通过 go install 安装指定工具
ensure_go_tool() {
    local binary_name="$1"
    local module_path="$2"
    local version_tag="$3"

    if command -v "$binary_name" >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v go >/dev/null 2>&1; then
        log_error "Go 未安装，无法安装 $binary_name"
        return 1
    fi

    local install_ref
    if [[ -n "$version_tag" && "$version_tag" != "latest" ]]; then
        install_ref="$module_path@$version_tag"
    else
        install_ref="$module_path@latest"
    fi

    log_info "安装 $binary_name (go install $install_ref) ..."
    if ! GO111MODULE=on go install "$install_ref" >/dev/null 2>&1; then
        log_error "$binary_name 安装失败"
        return 1
    fi

    local go_bin
    go_bin="$(go env GOPATH 2>/dev/null)/bin"
    add_path_if_missing "$go_bin"

    if command -v "$binary_name" >/dev/null 2>&1; then
        log_success "$binary_name 已安装"
        return 0
    fi

    log_warning "$binary_name 已安装但当前 PATH 未包含其目录"
    return 0
}

# 检查并安装 golangci-lint(版本/模块路径见顶部 MTK_GOLANGCI_*)
ensure_golangci_lint() {
    if [[ "${DISABLE_GOLANGCI_LINT:-0}" == "1" ]]; then
        log_warning "golangci-lint 已禁用 (DISABLE_GOLANGCI_LINT=1)"
        return 0
    fi
    ensure_go_tool "golangci-lint" "$MTK_GOLANGCI_MODULE" "$MTK_GOLANGCI_VERSION" || log_warning "golangci-lint 安装失败"
}

# 检查并安装 goimports
ensure_goimports() {
    ensure_go_tool "goimports" "golang.org/x/tools/cmd/goimports" "latest" || log_warning "goimports 安装失败"
}

# 检查并安装 gofumpt
ensure_gofumpt() {
    ensure_go_tool "gofumpt" "mvdan.cc/gofumpt" "latest" || log_warning "gofumpt 安装失败"
}

# 获取项目根目录（兜底用；通常由 quality.mk 注入 PROJECT_ROOT=$(CURDIR)）
get_project_root() {
    # 1) git 顶层目录
    local top
    if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        echo "$top"
        return 0
    fi
    # 2) 调用 make 时的工作目录
    echo "$(pwd)"
}

# 获取 CPU 核心数（兼容 macOS / Linux）
get_cpu_count() {
    local os
    os="$(uname -s)"
    case "$os" in
        Darwin)
            sysctl -n hw.ncpu 2>/dev/null || echo 4
            ;;
        Linux)
            if command -v nproc >/dev/null 2>&1; then
                nproc
            else
                getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
            fi
            ;;
        *)
            getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
            ;;
    esac
}

# 自动发现包含 go.mod 的模块目录（相对 PROJECT_ROOT；根含 go.mod 输出 "."）
discover_go_modules() {
    local root="${1:-${PROJECT_ROOT:-$(pwd)}}"
    local gomod d
    while IFS= read -r gomod; do
        [[ -z "$gomod" ]] && continue
        d="$(cd "$(dirname "$gomod")" && pwd)"
        if [[ "$d" == "$root" ]]; then
            echo "."
        else
            echo "${d#"${root}"/}"
        fi
    done < <(find "$root" \
        \( -name vendor -o -name node_modules -o -name .git -o -name testdata -o -name dist \) -prune -o \
        -name go.mod -print 2>/dev/null | sort)
}

# 解析要处理的 Go 模块列表：优先 GO_MODULES（逗号/空格分隔），否则自动发现 go.mod
resolve_go_modules() {
    if [[ -n "${GO_MODULES:-}" ]]; then
        local m
        for m in ${GO_MODULES//,/ }; do
            [[ -n "$m" ]] && echo "$m"
        done
    else
        discover_go_modules "${PROJECT_ROOT:-$(pwd)}"
    fi
}

export MTK_GOLANGCI_VERSION MTK_GOLANGCI_MODULE
export -f log_info log_success log_warning log_error log_step
export -f add_path_if_missing contains_item ensure_go_tool
export -f ensure_golangci_lint ensure_goimports ensure_gofumpt
export -f get_project_root get_cpu_count discover_go_modules resolve_go_modules

# 颜色别名:兼容直接使用 $RED/$GREEN/… 的旧脚本(run-tests.sh 等)
RED=$C_ERR; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO; CYAN=$C_ACCENT; NC=$C_RESET
export RED GREEN YELLOW BLUE CYAN NC
