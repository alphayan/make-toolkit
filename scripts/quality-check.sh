#!/bin/bash

# 代码质量检查脚本（通用化）
# 执行 go vet 与 golangci-lint（已涵盖 staticcheck、ineffassign 等）。
# 模块列表来自 GO_MODULES，留空则自动发现 go.mod。
# QUALITY_EXCLUDE 排除的目录正则（默认 'e2e|docs'，按路径段匹配，同 RACE_EXCLUDE 风格）。

set -e

# 加载公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

# 默认配置
: "${GOLANGCI_TIMEOUT:=5m}"
: "${QUALITY_EXCLUDE:=e2e|docs}"

# 收集模块内待检查的包模式：模块根有 .go 输出 "."，其余含 .go 的目录输出 "./dir/..."；
# 排除路径段命中 QUALITY_EXCLUDE 的目录，以及 vendor/node_modules/testdata/.git。
collect_quality_packages() {
    local module_dir="$1"
    local dir
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if [[ "$dir" == "." ]]; then
            echo "."
        else
            echo "./$dir/..."
        fi
    done < <(cd "$module_dir" && \
        find . \( -name vendor -o -name node_modules -o -name testdata -o -name .git \) -prune -o \
            -type f -name "*.go" -print 2>/dev/null \
        | sed 's|/[^/]*$||; s|^\./||' \
        | sort -u \
        | grep -Ev "(^|/)(${QUALITY_EXCLUDE})(/|\$)" || true)
}

# 针对单个 Go 模块执行质量检查
run_go_module_quality_checks() {
    local module="$1"
    local module_dir="$PROJECT_ROOT/$module"

    if [[ ! -d "$module_dir" ]]; then
        return 0
    fi

    log_info "模块 $module: 开始质量检查"

    local packages=()
    local pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(collect_quality_packages "$module_dir")

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "模块 $module: 无待检查的 Go 包（排除 ${QUALITY_EXCLUDE} 后），跳过"
        return 0
    fi

    # 步骤 1: go vet
    log_info "模块 $module: 执行 go vet"
    if ! (cd "$module_dir" && GO111MODULE=on go vet "${packages[@]}"); then
        log_error "模块 $module: go vet 未通过"
        return 1
    fi

    # 步骤 2: golangci-lint（已包含 staticcheck、ineffassign 等）
    if [[ "${DISABLE_GOLANGCI_LINT:-0}" == "1" ]]; then
        log_warning "模块 $module: golangci-lint 已禁用（DISABLE_GOLANGCI_LINT=1），跳过"
    elif command -v golangci-lint >/dev/null 2>&1; then
        log_info "模块 $module: 执行 golangci-lint 代码检查..."
        if ! (cd "$module_dir" && golangci-lint run --allow-parallel-runners --timeout "$GOLANGCI_TIMEOUT" "${packages[@]}"); then
            log_error "模块 $module: golangci-lint 未通过"
            return 1
        fi
        log_success "模块 $module: golangci-lint 代码检查通过"
    else
        log_warning "未检测到 golangci-lint，跳过（go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest）"
    fi

    log_success "模块 $module: 质量检查通过"
    return 0
}

# 执行所有模块的质量检查（顺序执行模式）
run_go_quality_checks() {
    if [[ "${SKIP_CHECKS:-0}" == "1" ]]; then
        log_warning "跳过质量检查 (SKIP_CHECKS=1)"
        return 0
    fi

    # 模块列表：GO_MODULES 优先，否则自动发现 go.mod
    local modules=()
    local _m
    while IFS= read -r _m; do
        [[ -n "$_m" ]] && modules+=("$_m")
    done < <(resolve_go_modules)

    if [[ ${#modules[@]} -eq 0 ]]; then
        log_warning "未发现任何 Go 模块（可设置 GO_MODULES，或确保存在 go.mod）"
        return 0
    fi

    local failed_modules=()
    for module in "${modules[@]}"; do
        log_info "启动 $module 质量检查（顺序执行）..."
        if run_go_module_quality_checks "$module"; then
            log_success "$module 质量检查通过"
        else
            log_error "$module 质量检查失败"
            failed_modules+=("$module")
        fi
    done

    if [[ ${#failed_modules[@]} -gt 0 ]]; then
        log_error "以下模块质量检查失败: ${failed_modules[*]}"
        return 1
    fi

    log_success "所有模块质量检查通过（顺序执行）"
    return 0
}

# 主函数
main() {
    log_step "开始代码质量检查..."
    ensure_golangci_lint
    run_go_quality_checks
    log_success "代码质量检查完成"
}

main "$@"
