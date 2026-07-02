#!/bin/bash

# 代码格式化脚本（通用化）
# 使用 gofumpt（Go 增强格式化）、goimports 和 modernize 将代码升级到最新 Go 风格。
# 模块列表来自 FORMAT_MODULES / GO_MODULES，留空则自动发现 go.mod。
# MODERNIZE_VERSION 可钉住 modernize 版本（默认 latest，即 gopls 模块的最新版）。

# 注意：不在全局设置 set -e，以便并发执行时能正确收集错误

# 加载公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

# 默认配置
: "${DRY_RUN:=0}"
: "${MODERNIZE_VERSION:=latest}"

# 对单个模块执行格式化
format_module() {
    local module="$1"
    local module_dir="$PROJECT_ROOT/$module"

    if [[ ! -d "$module_dir" ]]; then
        log_warning "模块 $module 不存在，跳过"
        return 0
    fi

    log_info "模块 $module: 开始代码格式化..."

    # 步骤 1: modernize - 升级到最新 Go 风格（可选）
    # 所有启用的分析器一次跑完（单次 go run，避免重复解析/构建 gopls 模块）
    if [[ "${SKIP_MODERNIZE:-0}" != "1" ]]; then
        log_info "模块 $module: 执行 modernize 代码风格升级..."
        local modernize_args=(-any -minmax -slicescontains -slicessort -stringscut -stringscutprefix -forvar -rangeint -test ./...)
        if [[ "${DRY_RUN}" != "1" ]]; then
            modernize_args=(-fix "${modernize_args[@]}")
        fi
        if ! (cd "$module_dir" && go run "golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize@${MODERNIZE_VERSION}" \
            "${modernize_args[@]}"); then
            log_warning "模块 $module: modernize 执行失败，继续"
        fi
    else
        log_info "模块 $module: modernize 跳过（SKIP_MODERNIZE=1）"
    fi

    # 步骤 2: gofumpt - Go 增强格式化（比 gofmt 更严格）
    log_info "模块 $module: 执行 gofumpt 增强格式化..."
    if command -v gofumpt >/dev/null 2>&1; then
        local gofumpt_args=(-w .)
        if [[ "${DRY_RUN}" == "1" ]]; then
            gofumpt_args=(-d .)
        fi
        if ! (cd "$module_dir" && gofumpt "${gofumpt_args[@]}"); then
            log_warning "模块 $module: gofumpt 格式化失败，继续执行其他工具"
        fi
    else
        log_warning "未检测到 gofumpt，回退到 gofmt（可通过 go install mvdan.cc/gofumpt@latest 安装）"
        if ! (cd "$module_dir" && go fmt ./...); then
            log_warning "模块 $module: 格式化失败，继续执行其他工具"
        fi
    fi

    # 步骤 3: goimports - 整理导入并自动插入缺失的导入
    if command -v goimports >/dev/null 2>&1; then
        log_info "模块 $module: 执行 goimports 整理导入..."
        local goimports_args=(-w .)
        if [[ "${DRY_RUN}" == "1" ]]; then
            goimports_args=(-d .)
        fi
        if ! (cd "$module_dir" && goimports "${goimports_args[@]}"); then
            log_warning "模块 $module: goimports 执行失败，继续"
        fi
    else
        log_warning "未检测到 goimports，跳过（可通过 go install golang.org/x/tools/cmd/goimports@latest 安装）"
    fi

    log_success "模块 $module: 代码格式化完成"
}

# 主函数
main() {
    local dry_run_msg=""
    if [[ "${DRY_RUN}" == "1" ]]; then
        dry_run_msg=" (DRY_RUN=1，仅显示将要格式化的文件)"
    fi

    log_step "开始代码格式化${dry_run_msg}..."

    # 确保格式化工具已安装（这些步骤失败应该导致脚本退出）
    set -e
    ensure_gofumpt
    ensure_goimports
    set +e

    # 解析模块列表：FORMAT_MODULES（逗号/空格）优先，否则自动发现 go.mod
    local modules=()
    local _m
    if [[ -n "${FORMAT_MODULES:-}" ]]; then
        for _m in ${FORMAT_MODULES//,/ }; do
            [[ -n "$_m" ]] && modules+=("$_m")
        done
    else
        while IFS= read -r _m; do
            [[ -n "$_m" ]] && modules+=("$_m")
        done < <(resolve_go_modules)
    fi

    if [[ ${#modules[@]} -eq 0 ]]; then
        log_warning "未发现任何 Go 模块（可设置 GO_MODULES / FORMAT_MODULES，或确保存在 go.mod）"
        exit 0
    fi

    # 并发执行每个模块的格式化
    local pids=()
    local module_names=()
    local failed_modules=()

    for module in "${modules[@]}"; do
        module="${module// /}"  # 移除空格
        if [[ -n "$module" ]]; then
            module_names+=("$module")
            (
                set +e
                format_module "$module"
                exit $?
            ) &
            pids+=($!)
        fi
    done

    # 等待所有后台任务完成并收集结果
    local idx=0
    for pid in "${pids[@]}"; do
        wait "$pid"
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            failed_modules+=("${module_names[$idx]}")
        fi
        ((idx++))
    done

    # 显示汇总结果
    if [[ ${#failed_modules[@]} -eq 0 ]]; then
        log_success "所有模块代码格式化完成"
    else
        log_error "以下模块格式化失败: ${failed_modules[*]}"
        exit 1
    fi

    echo ""
    echo "格式化后的建议："
    echo "  1. 检查 git diff 查看变更内容"
    echo "  2. 运行 make test 确保测试通过"
    echo "  3. 运行 make lint 进行代码质量检查"
}

main "$@"
