#!/bin/bash

# 代码质量检查脚本（通用化）
# 执行 go vet 与 golangci-lint（已涵盖 staticcheck、ineffassign 等）。
# 模块列表来自 GO_MODULES，留空则自动发现 go.mod。

set -e

# 加载公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

# 默认配置
: "${GOLANGCI_LINT_VERSION:=v1.60.3}"
: "${GOLANGCI_TIMEOUT:=5m}"

# 收集模块内所有 Go 目录
collect_changed_go_dirs() {
    local module="$1"
    local module_path="$PROJECT_ROOT/$module"

    if [[ ! -d "$module_path" ]]; then
        echo "."
        return 0
    fi

    local dirs=()
    while IFS= read -r dir; do
        if [[ -n "$dir" && "$dir" != "./e2e"* && "$dir" != "./docs"* && "$dir" != "./query"* ]]; then
            dir="${dir#./}"
            if [[ "$dir" != "." && "$dir" != "e2e" && "$dir" != "docs" && "$dir" != "query" ]]; then
                if ! contains_item "$dir" "${dirs[@]}"; then
                    dirs+=("$dir")
                fi
            fi
        fi
    done < <(cd "$module_path" && find . -name "*.go" -not -path "./e2e/*" -not -path "./docs/*" -not -path "./query/*" | xargs dirname | sort -u | sed 's|^\./||' | sed 's|^$|.|')

    if [[ ${#dirs[@]} -eq 0 ]]; then
        echo "."
    else
        local d
        for d in "${dirs[@]}"; do
            echo "$d"
        done
    fi
}

# 针对单个 Go 模块执行质量检查
run_go_module_quality_checks() {
    local module="$1"
    local module_dir="$PROJECT_ROOT/$module"

    if [[ ! -d "$module_dir" ]]; then
        return 0
    fi

    log_info "模块 $module: 开始质量检查"

    local dir_targets=()
    while IFS= read -r dir_line; do
        if [[ -z "$dir_line" ]]; then
            continue
        fi
        if [[ "$dir_line" == e2e* ]] || [[ "$dir_line" == query* ]]; then
            continue
        fi
        dir_targets+=("$dir_line")
    done < <(collect_changed_go_dirs "$module")

    if [[ ${#dir_targets[@]} -eq 0 ]]; then
        dir_targets=(".")
    fi

    local packages=()
    for dir in "${dir_targets[@]}"; do
        local pkg
        if [[ "$dir" == "." ]]; then
            while IFS= read -r pkg_path; do
                if [[ -n "$pkg_path" && "$pkg_path" != "./e2e"* && "$pkg_path" != "./docs"* && "$pkg_path" != "./query"* ]]; then
                    if ! contains_item "$pkg_path" "${packages[@]}"; then
                        packages+=("$pkg_path")
                    fi
                fi
            done < <(cd "$module_dir" && find . -name "*.go" -not -path "./e2e/*" -not -path "./docs/*" -not -path "./query/*" | xargs dirname | sort -u | sed 's|^\./||' | sed 's|^$|.|' | sed 's|^|./|')
        else
            pkg="./$dir/..."
            if ! contains_item "$pkg" "${packages[@]}"; then
                packages+=("$pkg")
            fi
        fi
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        packages=("./...")
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
