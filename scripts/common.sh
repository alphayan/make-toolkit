#!/bin/bash

# make-toolkit 公共函数库
# 提供日志、工具安装、Go 模块发现等公共功能。
# 来源：从一套多模块 Go 项目的 deploy/scripts 通用化而来。

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

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

# 检查并安装 golangci-lint
ensure_golangci_lint() {
    local version="${GOLANGCI_LINT_VERSION:-v1.60.3}"
    if [[ "${DISABLE_GOLANGCI_LINT:-0}" == "1" ]]; then
        log_warning "golangci-lint 已禁用 (DISABLE_GOLANGCI_LINT=1)"
        return 0
    fi
    ensure_go_tool "golangci-lint" "github.com/golangci/golangci-lint/cmd/golangci-lint" "$version" || log_warning "golangci-lint 安装失败"
}

# 检查并安装 staticcheck
ensure_staticcheck() {
    local version="${STATICCHECK_VERSION:-2023.1.6}"
    ensure_go_tool "staticcheck" "honnef.co/go/tools/cmd/staticcheck" "$version" || log_warning "staticcheck 安装失败"
}

# 检查并安装 ineffassign
ensure_ineffassign() {
    local version="${INEFFASSIGN_VERSION:-latest}"
    ensure_go_tool "ineffassign" "github.com/gordonklaus/ineffassign" "$version" || log_warning "ineffassign 安装失败"
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

export -f log_info log_success log_warning log_error log_step
export -f add_path_if_missing contains_item ensure_go_tool
export -f ensure_golangci_lint ensure_staticcheck ensure_ineffassign ensure_goimports ensure_gofumpt
export -f get_project_root get_cpu_count discover_go_modules resolve_go_modules
