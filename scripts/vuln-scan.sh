#!/bin/bash

# 依赖漏洞扫描脚本（通用化）
# 顺序执行 Go 专门扫描 (govulncheck) 和 全项目通用扫描 (Trivy)。
# 后端 Go 模块来自 GO_MODULES（留空则自动发现 go.mod）；
# 前端 / 整个仓库由 Trivy fs 扫描，自动跳过 node_modules/dist/vendor/.git。

set -e

# 加载公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

# 默认配置
: "${VULN_SEVERITY:=CRITICAL,HIGH}"
: "${TRIVY_SCANNERS:=vuln}"
: "${SKIP_VULN:=0}"
: "${TRIVY_SKIP_DIRS:=}"

# Go 专门漏洞扫描 (govulncheck)
run_govulncheck() {
    if ! command -v go >/dev/null 2>&1; then
        log_warning "未安装 Go，跳过 govulncheck 扫描"
        return 0
    fi

    log_info "🔍 执行 Go 专门漏洞扫描 (govulncheck)..."

    local gv_bin
    gv_bin="$(go env GOPATH 2>/dev/null)/bin/govulncheck"
    if [[ ! -x "${gv_bin}" ]] && ! command -v govulncheck >/dev/null 2>&1; then
        log_info "尝试安装 govulncheck..."
        # 注:module 路径须与 common.sh 的 MTK_GO_TOOLS 中 govulncheck 条目保持一致
        go install golang.org/x/vuln/cmd/govulncheck@latest || true
    fi

    if command -v govulncheck >/dev/null 2>&1; then
        gv_bin="govulncheck"
    elif [[ ! -x "${gv_bin}" ]]; then
        log_warning "未发现 govulncheck，跳过此步"
        return 0
    fi

    # 模块列表：GO_MODULES 优先，否则自动发现 go.mod
    local modules=()
    local _m
    while IFS= read -r _m; do
        [[ -n "$_m" ]] && modules+=("$_m")
    done < <(resolve_go_modules)

    if [[ ${#modules[@]} -eq 0 ]]; then
        log_warning "未发现任何 Go 模块，跳过 govulncheck"
        return 0
    fi

    local exit_code=0
    for mod in "${modules[@]}"; do
        if [[ -d "${PROJECT_ROOT}/${mod}" ]]; then
            log_info "扫描模块: ${mod}"
            set +e
            (cd "${PROJECT_ROOT}/${mod}" && "${gv_bin}" ./...)
            local rc=$?
            set -e
            if (( rc != 0 )); then
                log_error "模块 ${mod} 发现漏洞"
                exit_code=1
            fi
        fi
    done

    return ${exit_code}
}

# 全项目通用漏洞扫描 (Trivy)
run_trivy() {
    local severity="${VULN_SEVERITY:-CRITICAL,HIGH}"
    local scanners="${TRIVY_SCANNERS:-vuln}"

    log_info "🔍 执行全项目通用漏洞扫描 (Trivy, severity=${severity})..."

    # Trivy 缓存目录
    local trivy_cache_dir="${PROJECT_ROOT}/.build-cache/trivy"
    mkdir -p "$trivy_cache_dir"

    # 需要跳过的依赖/产物目录（相对路径），始终跳过 + 用户附加
    local skip_rel=()
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        skip_rel+=("${d#"${PROJECT_ROOT}"/}")
    done < <(find "${PROJECT_ROOT}" -type d \( -name node_modules -o -name dist -o -name vendor -o -name .git \) -prune -print 2>/dev/null)
    local extra
    for extra in ${TRIVY_SKIP_DIRS//,/ }; do
        [[ -n "$extra" ]] && skip_rel+=("$extra")
    done

    # 需要跳过的敏感文件（避免对密钥/证书做无意义的漏洞扫描）
    local skip_files_rel=()
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        skip_files_rel+=("${f#"${PROJECT_ROOT}"/}")
    done < <(find "${PROJECT_ROOT}" \
        \( -name node_modules -o -name dist -o -name .git -o -name vendor \) -prune -false -o \
        -type f \
        \( -name "*.pem" -o -name "*.key" -o -name "*.p8" -o -name "*.p12" -o -name "*.der" \
           -o -name "*.crt" -o -name "*.cer" -o -name "*.keystore" -o -name "*.jks" \
           -o -name ".env" -o -name ".env.*" \) \
        -print 2>/dev/null || true)

    # 拼接参数。Trivy 的 --skip-dirs/--skip-files 按相对扫描根的路径匹配
    # （官方文档示例均为相对路径），绝对路径会静默失配，本机/容器统一传相对路径。
    # 用数组逐参传递，避免含空格/元字符的路径被 word splitting 拆错或注入额外参数。
    local TRIVY_SKIP_ARGS=()
    local r
    for r in "${skip_rel[@]}"; do
        TRIVY_SKIP_ARGS+=(--skip-dirs "$r")
    done
    for r in "${skip_files_rel[@]}"; do
        TRIVY_SKIP_ARGS+=(--skip-files "$r")
    done

    local scan_rc=0
    if command -v trivy >/dev/null 2>&1; then
        log_info "使用本机 Trivy 扫描"
        set +e
        trivy fs --scanners "${scanners}" --no-progress --ignore-unfixed --exit-code 1 --severity "${severity}" \
            --cache-dir "$trivy_cache_dir" \
            "${TRIVY_SKIP_ARGS[@]}" \
            "${PROJECT_ROOT}"
        scan_rc=$?
        set -e
    elif command -v docker >/dev/null 2>&1; then
        local trivy_image="${TRIVY_IMAGE:-aquasec/trivy:latest}"
        log_info "使用 Trivy 容器扫描 (${trivy_image})"
        set +e
        docker run --rm \
            -v "${PROJECT_ROOT}:/src" \
            -v "${trivy_cache_dir}:/root/.cache/trivy" \
            -w /src "${trivy_image}" \
            fs --scanners "${scanners}" --no-progress --ignore-unfixed --exit-code 1 --severity "${severity}" \
            "${TRIVY_SKIP_ARGS[@]}" \
            /src
        scan_rc=$?
        set -e
    else
        log_warning "未发现 Trivy，跳过全项目扫描（brew install trivy 或安装 Docker）"
        return 0
    fi

    return ${scan_rc}
}

# 依赖漏洞扫描主入口
vuln_scan() {
    if [[ "${SKIP_VULN:-0}" == "1" ]]; then
        log_info "跳过依赖漏洞扫描 (SKIP_VULN=1)"
        return 0
    fi

    log_step "开始漏洞双重扫描策略（govulncheck + Trivy）"
    log_info "💡 提示: 如需跳过漏洞扫描可使用 SKIP_VULN=1"

    local final_rc=0
    local gv_rc=0
    local trivy_rc=0

    if run_govulncheck; then
        gv_rc=0
    else
        gv_rc=$?
    fi
    if (( gv_rc != 0 )); then
        final_rc=1
    fi

    echo ""

    if run_trivy; then
        trivy_rc=0
    else
        trivy_rc=$?
    fi
    if (( trivy_rc != 0 )); then
        final_rc=1
    fi

    if (( final_rc != 0 )); then
        log_error "扫描完成：发现安全漏洞，请及时修复"
        return 1
    fi

    log_success "所有扫描完成，未发现高危漏洞"
    return 0
}

main() {
    vuln_scan
}

main "$@"
