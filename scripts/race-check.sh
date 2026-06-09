#!/bin/bash

# Go race 检测（通用化、可移植子集）
# 仅保留 `go test -race` 核心；原版基于 docker-compose 的并发压测 / 日志巡检
# 强依赖具体服务部署，不可移植，已移除。
#
# 配置：
#   RACE_TIMEOUT  单包超时（默认 5m）
#   RACE_EXCLUDE  排除的包路径正则（默认 'e2e|docs'）
#   RACE_MODULES  指定模块（逗号分隔），留空则用 GO_MODULES / 自动发现

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

: "${RACE_TIMEOUT:=5m}"
: "${RACE_EXCLUDE:=e2e|docs}"

run_race_for_module() {
    local mod_dir="$1"
    local timeout="$2"
    local cpu_n
    cpu_n=$(get_cpu_count)

    if [[ ! -d "$mod_dir" ]]; then
        log_warning "未找到模块目录: $mod_dir，跳过 -race 测试"
        return 0
    fi

    log_step "执行 -race 测试: $mod_dir (timeout=${timeout}, exclude=${RACE_EXCLUDE})"
    cd "$mod_dir"

    local pkgs
    pkgs=$(go list ./... 2>/dev/null | grep -Ev "/(${RACE_EXCLUDE})(\$|/)" || true)
    if [[ -z "$pkgs" ]]; then
        log_info "无可测试包（已排除 ${RACE_EXCLUDE}）: $mod_dir"
        return 0
    fi

    # 并行逐包执行 -race 测试。
    # 包路径与 timeout 作为位置参数传入内层 sh，绝不拼进脚本字符串，
    # 避免含元字符的包路径被 shell 二次解析（命令注入 / 解析错误）。
    echo "$pkgs" | xargs -n 1 -P "$cpu_n" -I {} \
        sh -c 'go test -race -count=1 -timeout="$1" "$2"' mtk-race "$timeout" {}
}

show_help() {
    echo "Go race 检测（通用化）"
    echo "用法: race-check.sh [--modules a,b] [--timeout 5m]"
    echo "  --modules MODULES  指定模块（逗号分隔），默认 GO_MODULES / 自动发现"
    echo "  --timeout DURATION 单包超时（默认 ${RACE_TIMEOUT}）"
}

main() {
    local timeout="$RACE_TIMEOUT"
    local modules_arg=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --modules) modules_arg="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --help|-h) show_help; exit 0 ;;
            *) log_error "未知参数: $1"; show_help; exit 1 ;;
        esac
    done

    [[ -z "$modules_arg" && -n "${RACE_MODULES:-}" ]] && modules_arg="$RACE_MODULES"

    local modules=()
    local _m
    if [[ -n "$modules_arg" ]]; then
        for _m in ${modules_arg//,/ }; do
            [[ -n "$_m" ]] && modules+=("$_m")
        done
    else
        while IFS= read -r _m; do
            [[ -n "$_m" ]] && modules+=("$_m")
        done < <(resolve_go_modules)
    fi

    if [[ ${#modules[@]} -eq 0 ]]; then
        log_warning "未发现任何 Go 模块"
        exit 0
    fi

    log_step "执行 Go race 检测（模块: ${modules[*]}, 超时: $timeout）"
    echo ""

    local m
    for m in "${modules[@]}"; do
        run_race_for_module "$PROJECT_ROOT/$m" "$timeout" || exit 1
    done

    log_success "所有模块 race 检测完成"
}

main "$@"
