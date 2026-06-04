#!/usr/bin/env bash
# make-toolkit 自包含安装器(由 build-installer.sh 自动生成,请勿手改)
#
# 把 Go 代码质量工具链拷贝进目标项目并接好 Makefile:
#   make scan / format / quality-check / lint / test / test-coverage / race-check / cloc
# 不用 git submodule、不依赖任何远程仓库,拷进去的文件随项目自身仓库提交即可。
#
# 用法:
#   bash install.sh [目标项目目录]        # 默认当前目录
#   bash install.sh --into deps/mtk DIR   # 自定义 vendor 子目录(默认 make-toolkit)
#   bash install.sh --no-color DIR        # 关闭彩色输出
#   bash install.sh --skip-doctor DIR     # 跳过装前环境自检
#   bash install.sh --help
set -euo pipefail

VENDOR_SUBDIR="make-toolkit"
TARGET=""
SKIP_DOCTOR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --into) VENDOR_SUBDIR="${2:?--into 需要一个目录名}"; shift 2 ;;
    --no-color) export MTK_NO_COLOR=1; shift ;;
    --skip-doctor) SKIP_DOCTOR=1; shift ;;
    -h|--help)
      cat <<'USAGE'
make-toolkit 安装器
  bash install.sh [目标项目目录]        默认当前目录
  bash install.sh --into deps/mtk DIR   自定义 vendor 子目录
  bash install.sh --no-color DIR        关闭彩色输出
  bash install.sh --skip-doctor DIR     跳过装前自检
拷贝 quality.mk + scripts/ 进目标项目的 <子目录>/,并在其 Makefile 接入
`include <子目录>/quality.mk`。可重复运行以更新脚本(幂等)。
USAGE
      exit 0 ;;
    --*) echo "未知参数: $1" >&2; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-$PWD}"
if [[ ! -d "$TARGET" ]]; then echo "目标目录不存在: $TARGET" >&2; exit 1; fi
TARGET="$(cd "$TARGET" && pwd)"
DEST="$TARGET/$VENDOR_SUBDIR"

# ===== embedded: scripts/ui.sh =====
# make-toolkit UI 组件库 — 纯 bash,零依赖,兼容 bash 3.2(不使用关联数组)。
# 三级颜色降级:truecolor / ansi8 / none。被 common.sh source,也被 install.sh 内联。

[[ -n "${MTK_UI_LOADED:-}" ]] && return 0 2>/dev/null
MTK_UI_LOADED=1

MTK_COLOR_MODE=""
C_RESET=""; C_BOLD=""; C_DIM=""
C_ACCENT=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUTED=""
ICON_INFO="[INFO]"; ICON_OK="[OK]"; ICON_WARN="[WARN]"; ICON_ERR="[ERROR]"; ICON_STAGE="-"

# 判定颜色模式并填充颜色/图标变量。
ui_init_colors() {
    if [[ "${MTK_NO_COLOR:-0}" == "1" || -n "${NO_COLOR+x}" || "${TERM:-dumb}" == "dumb" || ! -t 1 ]]; then
        MTK_COLOR_MODE="none"
    elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        MTK_COLOR_MODE="truecolor"
    else
        MTK_COLOR_MODE="ansi8"
    fi

    if [[ "$MTK_COLOR_MODE" == "none" ]]; then
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_ACCENT=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUTED=""
        ICON_INFO="[INFO]"; ICON_OK="[OK]"; ICON_WARN="[WARN]"; ICON_ERR="[ERROR]"; ICON_STAGE="-"
        return 0
    fi

    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    ICON_INFO="i"; ICON_OK="OK"; ICON_WARN="!"; ICON_ERR="x"; ICON_STAGE=">"
    if [[ "$MTK_COLOR_MODE" == "truecolor" ]]; then
        C_ACCENT=$'\033[38;2;0;191;165m'
        C_INFO=$'\033[38;2;136;146;176m'
        C_OK=$'\033[38;2;0;200;120m'
        C_WARN=$'\033[38;2;255;176;32m'
        C_ERR=$'\033[38;2;230;57;70m'
        C_MUTED=$'\033[38;2;120;130;150m'
    else
        C_ACCENT=$'\033[36m'; C_INFO=$'\033[34m'; C_OK=$'\033[32m'
        C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_MUTED=$'\033[2m'
    fi
}

ui_info()    { printf '%s%s%s %s\n' "$C_INFO"   "$ICON_INFO"  "$C_RESET" "$*"; }
ui_success() { printf '%s%s%s %s\n' "$C_OK"     "$ICON_OK"    "$C_RESET" "$*"; }
ui_warn()    { printf '%s%s%s %s\n' "$C_WARN"   "$ICON_WARN"  "$C_RESET" "$*" >&2; }
ui_error()   { printf '%s%s%s %s\n' "$C_ERR"    "$ICON_ERR"   "$C_RESET" "$*" >&2; }
ui_stage()   { printf '%s%s%s %s\n' "$C_ACCENT" "$ICON_STAGE" "$C_RESET" "$*"; }

ui_section() {
    printf '\n%s%s%s%s\n' "$C_BOLD" "$C_ACCENT" "$*" "$C_RESET"
    printf '%s%s%s\n' "$C_MUTED" "----------------------------------------" "$C_RESET"
}

# ui_kv KEY VALUE — 键左对齐到 14 列。
ui_kv() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }

# ui_panel — 从 stdin 读多行,加左边框(none 模式两空格缩进)。
ui_panel() {
    local line
    while IFS= read -r line; do
        if [[ "$MTK_COLOR_MODE" == "none" ]]; then
            printf '  %s\n' "$line"
        else
            printf '%s|%s %s\n' "$C_MUTED" "$C_RESET" "$line"
        fi
    done
}

ui_banner() {
    if [[ "$MTK_COLOR_MODE" == "none" ]]; then
        printf 'make-toolkit -- Go 代码质量工具链\n'
        return 0
    fi
    printf '\n%s%s make-toolkit %s%s\n' "$C_BOLD$C_ACCENT" "###" "###" "$C_RESET"
    printf '%sGo 代码质量工具链%s\n' "$C_MUTED" "$C_RESET"
}

# run_with_spinner DESC -- CMD...
# tty 下转圈;none/非 tty 打印 "DESC... done|failed"。捕获退出码,失败回显输出。
run_with_spinner() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    local tmp rc; tmp="$(mktemp)"
    if [[ "$MTK_COLOR_MODE" == "none" || ! -t 1 ]]; then
        printf '%s... ' "$desc"
        "$@" >"$tmp" 2>&1 &
        wait $! && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then printf 'done\n'; else printf 'failed\n'; cat "$tmp"; fi
        rm -f "$tmp"; return $rc
    fi
    local frames='|/-\' i=0 pid
    "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s%s%s %s' "$C_ACCENT" "${frames:$i:1}" "$C_RESET" "$desc"
        i=$(( (i + 1) % 4 ))
        sleep 0.1
    done
    wait "$pid" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '\r%s%s%s %s\n' "$C_OK" "$ICON_OK" "$C_RESET" "$desc"
    else
        printf '\r%s%s%s %s\n' "$C_ERR" "$ICON_ERR" "$C_RESET" "$desc"; cat "$tmp"
    fi
    rm -f "$tmp"; return $rc
}

export MTK_COLOR_MODE C_RESET C_BOLD C_DIM C_ACCENT C_INFO C_OK C_WARN C_ERR C_MUTED
export ICON_INFO ICON_OK ICON_WARN ICON_ERR ICON_STAGE
export -f ui_init_colors ui_info ui_success ui_warn ui_error ui_stage ui_section ui_kv ui_panel ui_banner run_with_spinner 2>/dev/null || true

# ===== embedded: scripts/common.sh =====

# make-toolkit 公共函数库
# 提供日志、工具安装、Go 模块发现等公共功能。
# 来源：从一套多模块 Go 项目的 deploy/scripts 通用化而来。

set -e

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

# ---- 工具清单:单一事实来源(供 ensure_* 与安装器 doctor 共用)----
# bash 3.2 无关联数组,用 "字段|字段" 字符串数组。
# MTK_GO_TOOLS 每项:binary|module|version|desc
MTK_GO_TOOLS=(
    "gofumpt|mvdan.cc/gofumpt|latest|格式化"
    "goimports|golang.org/x/tools/cmd/goimports|latest|整理导入"
    "golangci-lint|github.com/golangci/golangci-lint/cmd/golangci-lint|${GOLANGCI_LINT_VERSION:-v1.60.3}|质量检查(含 staticcheck/ineffassign)"
    "govulncheck|golang.org/x/vuln/cmd/govulncheck|latest|漏洞扫描"
)
# MTK_SYS_TOOLS 每项:binary|brew_install_hint|optional(yes/no)|desc
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

# 检查并安装 golangci-lint
ensure_golangci_lint() {
    local version="${GOLANGCI_LINT_VERSION:-v1.60.3}"
    if [[ "${DISABLE_GOLANGCI_LINT:-0}" == "1" ]]; then
        log_warning "golangci-lint 已禁用 (DISABLE_GOLANGCI_LINT=1)"
        return 0
    fi
    ensure_go_tool "golangci-lint" "github.com/golangci/golangci-lint/cmd/golangci-lint" "$version" || log_warning "golangci-lint 安装失败"
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
export -f ensure_golangci_lint ensure_goimports ensure_gofumpt
export -f get_project_root get_cpu_count discover_go_modules resolve_go_modules

# 颜色别名:兼容直接使用 $RED/$GREEN/… 的旧脚本(run-tests.sh 等)
RED=$C_ERR; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO; CYAN=$C_ACCENT; NC=$C_RESET
export RED GREEN YELLOW BLUE CYAN NC

# ===== embedded: installer/body.sh =====
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
    MTK_MISSING=()
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
            case "$(uname -s 2>/dev/null)" in
                Darwin) hint="$brewhint" ;;
                *)      hint="$(mtk_pkg_hint "$bin")" ;;
            esac
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


# ===== vendored files (written into target project) =====
vendor_files() {
  mkdir -p "$DEST/scripts"
  mkdir -p "$(dirname "$DEST/quality.mk")"
  cat > "$DEST/quality.mk" <<'MTK_EOF_quality_mk_'
# make-toolkit — 可复用的 Go 代码质量工具链
#
# 用法：在你项目根目录的 Makefile 里 include（建议先把本仓库加为 git submodule）：
#
#     include tools/make-toolkit/quality.mk
#
# 然后即可使用 make format / quality-check / scan / lint / test / race-check / cloc。
# 可在 include 之前覆盖下面的变量；留空则自动发现 go.mod。
#
# ⚠️ 注意：本文件会定义 format/quality-check/scan/lint/test/test-coverage/
#    test-verbose/race-check/cloc 这些目标，请勿在你的 Makefile 里重名。

# 本 .mk 所在目录（无论被谁 include 都能正确定位 scripts/）
MK_TOOLKIT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
MK_SCRIPTS := $(MK_TOOLKIT_DIR)/scripts

# 项目根：默认 = 调用 make 的目录
PROJECT_ROOT ?= $(CURDIR)

# ---- 可配置变量（留空则自动发现 go.mod）----
GO_MODULES       ?=
FORMAT_MODULES   ?=
TEST_MODULES     ?=
MODULE_ALIASES   ?=
COVERAGE_EXCLUDE ?=
VULN_SEVERITY    ?= CRITICAL,HIGH
TRIVY_SCANNERS   ?= vuln
TRIVY_SKIP_DIRS  ?=
RACE_TIMEOUT     ?= 5m
RACE_EXCLUDE     ?= e2e|docs
GOLANGCI_TIMEOUT ?= 5m

# 导出给脚本（未赋值的导出为空字符串，脚本内有默认值，无副作用）
export PROJECT_ROOT GO_MODULES FORMAT_MODULES TEST_MODULES MODULE_ALIASES COVERAGE_EXCLUDE
export VULN_SEVERITY TRIVY_SCANNERS TRIVY_SKIP_DIRS TRIVY_IMAGE
export RACE_TIMEOUT RACE_EXCLUDE RACE_MODULES
export GOLANGCI_TIMEOUT GOLANGCI_LINT_VERSION
export SKIP_VULN SKIP_CHECKS DISABLE_GOLANGCI_LINT SKIP_MODERNIZE WITH_TESTS

.PHONY: tk-help format quality-check scan lint test test-verbose test-coverage race-check cloc

tk-help:
	@echo "make-toolkit 目标："
	@echo "  make format         - gofumpt + goimports + modernize 格式化"
	@echo "  make quality-check  - go vet + golangci-lint"
	@echo "  make scan           - 依赖漏洞扫描（govulncheck + Trivy，前后端）"
	@echo "  make lint           - quality-check + scan"
	@echo "  make test           - 单元测试（指定模块: make test TEST_MODULES=\"a b\"）"
	@echo "  make test-verbose   - 单元测试（详细输出）"
	@echo "  make test-coverage  - 单元测试 + 覆盖率报告"
	@echo "  make race-check     - go test -race"
	@echo "  make cloc           - 代码行数统计（WITH_TESTS=1 含测试）"
	@echo ""
	@echo "配置变量（include 前覆盖；留空自动发现 go.mod）："
	@echo "  GO_MODULES FORMAT_MODULES TEST_MODULES MODULE_ALIASES COVERAGE_EXCLUDE"
	@echo "  VULN_SEVERITY TRIVY_SCANNERS TRIVY_SKIP_DIRS"
	@echo "  开关：SKIP_VULN=1 SKIP_CHECKS=1 DISABLE_GOLANGCI_LINT=1 SKIP_MODERNIZE=1"

format:
	@bash $(MK_SCRIPTS)/format-code.sh

quality-check:
	@bash $(MK_SCRIPTS)/quality-check.sh

scan:
	@bash $(MK_SCRIPTS)/vuln-scan.sh

lint: quality-check scan

test:
	@bash $(MK_SCRIPTS)/run-tests.sh

test-verbose:
	@bash $(MK_SCRIPTS)/run-tests.sh --verbose

test-coverage:
	@bash $(MK_SCRIPTS)/run-tests.sh --coverage

race-check:
	@bash $(MK_SCRIPTS)/race-check.sh

cloc:
	@bash $(MK_SCRIPTS)/cloc.sh
MTK_EOF_quality_mk_
  mkdir -p "$(dirname "$DEST/scripts/cloc.sh")"
  cat > "$DEST/scripts/cloc.sh" <<'MTK_EOF_scripts_cloc_sh_'
#!/bin/bash

# 代码行数统计（通用化）
# 默认排除测试文件；WITH_TESTS=1 则包含测试文件。
# 排除 .git / node_modules / vendor / dist。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"
cd "$PROJECT_ROOT"

INCLUDE_TESTS="${WITH_TESTS:-0}"

if [[ "$INCLUDE_TESTS" == "1" ]]; then
    log_step "统计代码行数（包含测试文件）..."
else
    log_step "统计代码行数（排除测试文件）..."
fi

if command -v cloc >/dev/null 2>&1; then
    if [[ "$INCLUDE_TESTS" == "1" ]]; then
        find . -type f \( -name "*.go" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.vue" \) \
            ! -path "*/.git/*" ! -path "*/node_modules/*" ! -path "*/vendor/*" ! -path "*/dist/*" \
            | cloc --list-file=- .
    else
        find . -type f \( -name "*.go" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.vue" \) \
            ! -path "*/.git/*" ! -path "*/node_modules/*" ! -path "*/vendor/*" ! -path "*/dist/*" ! -name "*_test.go" \
            | cloc --list-file=- .
    fi
else
    log_warning "cloc 不可用（brew install cloc），使用文件数量替代统计"
    echo ""
    count() { find . -type f ! -path "*/.git/*" ! -path "*/node_modules/*" ! -path "*/vendor/*" ! -path "*/dist/*" "$@" 2>/dev/null | wc -l | tr -d ' '; }
    if [[ "$INCLUDE_TESTS" == "1" ]]; then
        GO_FILES=$(count -name "*.go")
    else
        GO_FILES=$(find . -name "*.go" ! -path "*/.git/*" ! -path "*/vendor/*" ! -name "*_test.go" 2>/dev/null | wc -l | tr -d ' ')
    fi
    TS_FILES=$(count \( -name "*.ts" -o -name "*.tsx" \))
    JS_FILES=$(count -name "*.js")
    VUE_FILES=$(count -name "*.vue")
    echo "Go 文件:         $GO_FILES"
    echo "TypeScript 文件: $TS_FILES"
    echo "JavaScript 文件: $JS_FILES"
    echo "Vue 文件:        $VUE_FILES"
    echo "总文件数:        $(( GO_FILES + TS_FILES + JS_FILES + VUE_FILES ))"
fi
MTK_EOF_scripts_cloc_sh_
  mkdir -p "$(dirname "$DEST/scripts/common.sh")"
  cat > "$DEST/scripts/common.sh" <<'MTK_EOF_scripts_common_sh_'
#!/bin/bash

# make-toolkit 公共函数库
# 提供日志、工具安装、Go 模块发现等公共功能。
# 来源：从一套多模块 Go 项目的 deploy/scripts 通用化而来。

set -e

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

# ---- 工具清单:单一事实来源(供 ensure_* 与安装器 doctor 共用)----
# bash 3.2 无关联数组,用 "字段|字段" 字符串数组。
# MTK_GO_TOOLS 每项:binary|module|version|desc
MTK_GO_TOOLS=(
    "gofumpt|mvdan.cc/gofumpt|latest|格式化"
    "goimports|golang.org/x/tools/cmd/goimports|latest|整理导入"
    "golangci-lint|github.com/golangci/golangci-lint/cmd/golangci-lint|${GOLANGCI_LINT_VERSION:-v1.60.3}|质量检查(含 staticcheck/ineffassign)"
    "govulncheck|golang.org/x/vuln/cmd/govulncheck|latest|漏洞扫描"
)
# MTK_SYS_TOOLS 每项:binary|brew_install_hint|optional(yes/no)|desc
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

# 检查并安装 golangci-lint
ensure_golangci_lint() {
    local version="${GOLANGCI_LINT_VERSION:-v1.60.3}"
    if [[ "${DISABLE_GOLANGCI_LINT:-0}" == "1" ]]; then
        log_warning "golangci-lint 已禁用 (DISABLE_GOLANGCI_LINT=1)"
        return 0
    fi
    ensure_go_tool "golangci-lint" "github.com/golangci/golangci-lint/cmd/golangci-lint" "$version" || log_warning "golangci-lint 安装失败"
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
export -f ensure_golangci_lint ensure_goimports ensure_gofumpt
export -f get_project_root get_cpu_count discover_go_modules resolve_go_modules

# 颜色别名:兼容直接使用 $RED/$GREEN/… 的旧脚本(run-tests.sh 等)
RED=$C_ERR; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO; CYAN=$C_ACCENT; NC=$C_RESET
export RED GREEN YELLOW BLUE CYAN NC
MTK_EOF_scripts_common_sh_
  mkdir -p "$(dirname "$DEST/scripts/format-code.sh")"
  cat > "$DEST/scripts/format-code.sh" <<'MTK_EOF_scripts_format_code_sh_'
#!/bin/bash

# 代码格式化脚本（通用化）
# 使用 gofumpt（Go 增强格式化）、goimports 和 modernize 将代码升级到最新 Go 风格。
# 模块列表来自 FORMAT_MODULES / GO_MODULES，留空则自动发现 go.mod。

# 注意：不在全局设置 set -e，以便并发执行时能正确收集错误

# 加载公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"

# 默认配置
: "${DRY_RUN:=0}"

# 收集模块内所有 Go 目录
collect_go_dirs() {
    # 忽略 SIGPIPE 信号，防止管道中断导致 echo 失败
    trap '' PIPE

    local module="$1"
    local module_path="$PROJECT_ROOT/$module"

    if [[ ! -d "$module_path" ]]; then
        return 0
    fi

    while IFS= read -r dir; do
        if [[ -n "$dir" && "$dir" != "./e2e"* && "$dir" != "./docs"* && "$dir" != "./query"* ]]; then
            dir="${dir#./}"
            if [[ "$dir" != "." && "$dir" != "e2e" && "$dir" != "docs" && "$dir" != "query" ]]; then
                # 忽略 stderr 并确保失败不会中断脚本
                echo "$dir" 2>/dev/null || true
            fi
        fi
    done < <(cd "$module_path" && find . -name "*.go" -not -path "./e2e/*" -not -path "./docs/*" -not -path "./query/*" 2>/dev/null | xargs dirname 2>/dev/null | sort -u 2>/dev/null | sed 's|^\./||' 2>/dev/null | sed 's|^$|.|' 2>/dev/null || true)
}

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
    if [[ "${SKIP_MODERNIZE:-0}" != "1" ]]; then
        log_info "模块 $module: 执行 modernize 代码风格升级..."

        # 优先应用 efaceany 类别（interface{} -> any）
        if ! (cd "$module_dir" && go run golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize@latest -any -fix -test ./...); then
            log_warning "模块 $module: modernize any 执行失败，继续"
        fi

        # 然后应用其他现代化改进（启用推荐的分析器）
        if ! (cd "$module_dir" && go run golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize@latest \
            -minmax -slicescontains -slicessort -stringscut -stringscutprefix -forvar -rangeint \
            -fix -test ./...); then
            log_warning "模块 $module: modernize 其他类别执行失败，继续"
        fi
    else
        log_info "模块 $module: modernize 跳过（SKIP_MODERNIZE=1）"
    fi

    # 步骤 2: gofumpt - Go 增强格式化（比 gofmt 更严格）
    log_info "模块 $module: 执行 gofumpt 增强格式化..."
    if command -v gofumpt >/dev/null 2>&1; then
        if ! (cd "$module_dir" && gofumpt -w .); then
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
        if ! (cd "$module_dir" && goimports -w .); then
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
MTK_EOF_scripts_format_code_sh_
  mkdir -p "$(dirname "$DEST/scripts/quality-check.sh")"
  cat > "$DEST/scripts/quality-check.sh" <<'MTK_EOF_scripts_quality_check_sh_'
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
MTK_EOF_scripts_quality_check_sh_
  mkdir -p "$(dirname "$DEST/scripts/race-check.sh")"
  cat > "$DEST/scripts/race-check.sh" <<'MTK_EOF_scripts_race_check_sh_'
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

    # 并行逐包执行 -race 测试
    echo "$pkgs" | xargs -n 1 -P "$cpu_n" -I {} sh -c "go test -race -count=1 -timeout=${timeout} {}"
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
MTK_EOF_scripts_race_check_sh_
  mkdir -p "$(dirname "$DEST/scripts/run-tests.sh")"
  cat > "$DEST/scripts/run-tests.sh" <<'MTK_EOF_scripts_run_tests_sh_'
#!/bin/bash

# 统一单元测试脚本（通用化）
# 运行各 Go 模块的单元测试，支持覆盖率报告。
# 模块来自命令行参数 / TEST_MODULES / GO_MODULES，留空则自动发现 go.mod。
#
# 通用化配置：
#   MODULE_ALIASES   形如 "api=svc-api admin=svc-admin" 的别名映射（空格分隔，可选）
#   COVERAGE_EXCLUDE 覆盖率/测试包排除正则（默认 '/main$|/cmd|/docs'）

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 加载公共函数（resolve_go_modules / get_project_root 等）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# 定义变量
PROJECT_ROOT="${PROJECT_ROOT:-$(get_project_root)}"
COVERAGE_DIR="$PROJECT_ROOT/coverage_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GENERATE_COVERAGE=false

# 检查参数（默认启用 short 模式）
SHORT_MODE=true
VERBOSE_MODE=false
MODULE_ARGS=""

# 解析参数，支持 --verbose 关闭 short 模式
for arg in "$@"; do
    case "$arg" in
        --short)
            SHORT_MODE=true
            ;;
        --verbose)
            SHORT_MODE=false
            VERBOSE_MODE=true
            ;;
        --coverage)
            GENERATE_COVERAGE=true
            ;;
        *)
            if [[ -z "$MODULE_ARGS" ]]; then
                MODULE_ARGS="$arg"
            else
                MODULE_ARGS="$MODULE_ARGS $arg"
            fi
            ;;
    esac
done

# 如果没有命令行参数但有环境变量，检查环境变量
if [[ -z "$MODULE_ARGS" && -n "$TEST_MODULES" ]]; then
    MODULE_ARGS="$TEST_MODULES"
fi

# 模块别名映射（由 MODULE_ALIASES 驱动，默认恒等映射）
get_module_alias() {
    local key="$1" pair k v
    for pair in ${MODULE_ALIASES:-}; do
        k="${pair%%=*}"
        v="${pair#*=}"
        if [[ "$key" == "$k" ]]; then
            echo "$v"
            return 0
        fi
    done
    echo "$key"
}

# 解析模块参数
SELECTED_MODULES=()
if [[ -n "$MODULE_ARGS" ]]; then
    IFS=',' read -ra MODULE_LIST <<< "${MODULE_ARGS// /,}"
    for module in "${MODULE_LIST[@]}"; do
        module=$(echo "$module" | xargs)  # 去除前后空格
        [[ -z "$module" ]] && continue
        alias=$(get_module_alias "$module")
        SELECTED_MODULES+=("$alias")
    done
else
    # 默认：自动发现（或 GO_MODULES）
    while IFS= read -r _m; do
        [[ -n "$_m" ]] && SELECTED_MODULES+=("$_m")
    done < <(resolve_go_modules)
fi

if [[ ${#SELECTED_MODULES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}未发现任何 Go 模块（可指定 TEST_MODULES/GO_MODULES，或确保存在 go.mod）${NC}"
    exit 0
fi

# 创建覆盖率结果目录
mkdir -p "$COVERAGE_DIR"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              运行单元测试"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# 跟踪测试结果
PASSED_TESTS=0
FAILED_TESTS=0
COVERAGE_RESULTS=()

# 获取需要排除的包模式（用于过滤不测试的包）
get_exclude_patterns() {
    echo "${COVERAGE_EXCLUDE:-/main\$|/cmd|/docs}"
}

# 运行单个模块的测试
run_module_tests() {
    local module=$1
    local module_dir="$PROJECT_ROOT/$module"

    if [ ! -d "$module_dir" ]; then
        echo -e "${YELLOW}⚠ 模块 $module 不存在，跳过${NC}"
        return 0
    fi

    cd "$module_dir"

    local exclude_patterns
    exclude_patterns=$(get_exclude_patterns)

    local packages
    packages=$(go list ./... 2>/dev/null | grep -vE "$exclude_patterns" || true)

    local packages_array=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && packages_array+=("$pkg")
    done <<< "$packages"

    if [[ ${#packages_array[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ $module: 没有可测试的包（所有包已被排除）${NC}"
        return 0
    fi

    local tmp_output
    tmp_output=$(mktemp)
    local tmp_coverage=""

    local go_test_cmd="go test -timeout=10m -parallel=1"
    for pkg in "${packages_array[@]}"; do
        go_test_cmd="$go_test_cmd $pkg"
    done

    if [[ "$SHORT_MODE" == true ]]; then
        go_test_cmd="$go_test_cmd -short"
    fi

    if [[ "$GENERATE_COVERAGE" == true ]]; then
        tmp_coverage="$COVERAGE_DIR/${module//\//_}_coverage.out"
        go_test_cmd="$go_test_cmd -coverprofile=$tmp_coverage"
    fi

    if [[ "$VERBOSE_MODE" == true ]]; then
        echo -e "${BLUE}正在运行 $module 测试...${NC}"
        if eval "$go_test_cmd"; then
            echo -e "${GREEN}✓ $module 测试通过${NC}"
            if [[ "$GENERATE_COVERAGE" == true ]] && [ -f "$tmp_coverage" ]; then
                local coverage
                coverage=$(go tool cover -func="$tmp_coverage" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "0%")
                echo -e "  覆盖率: ${YELLOW}$coverage${NC}"
                COVERAGE_RESULTS+=("$module: $coverage")
                local html_file="$COVERAGE_DIR/${module//\//_}_coverage.html"
                go tool cover -html="$tmp_coverage" -o="$html_file" 2>/dev/null || true
                echo -e "  HTML 报告: $html_file"
            fi
            echo ""
            return 0
        else
            echo -e "${RED}✗ $module 测试失败${NC}"
            echo ""
            return 1
        fi
    else
        echo -e "${BLUE}正在运行 $module 测试...${NC}"
        if eval "$go_test_cmd" > "$tmp_output" 2>&1; then
            echo -e "${GREEN}✓ $module 测试通过${NC}"
            if [[ "$GENERATE_COVERAGE" == true ]] && [ -f "$tmp_coverage" ]; then
                local coverage
                coverage=$(go tool cover -func="$tmp_coverage" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "0%")
                echo -e "  覆盖率: ${YELLOW}$coverage${NC}"
                COVERAGE_RESULTS+=("$module: $coverage")
                local html_file="$COVERAGE_DIR/${module//\//_}_coverage.html"
                go tool cover -html="$tmp_coverage" -o="$html_file" 2>/dev/null || true
                echo -e "  HTML 报告: $html_file"
            fi
            rm -f "$tmp_output"
            echo ""
            return 0
        else
            echo -e "${RED}✗ $module 测试失败${NC}"
            # 过滤常见框架噪声（GORM/Redis/logx 等），仅突出失败信息
            awk '
                /^--- FAIL:/ {print; next}
                /^Error Trace:/ {print; next}
                /^Error:/ {print; next}
                /^panic:/ {print; next}
                /^Test:/ {print; next}
                /^ok[[:space:]]/ {next}
                /^\?/ {next}
                /^=== RUN/ {next}
                /^--- PASS/ {next}
                /^PASS([[:space:]]|$)/ {next}
                /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][[:space:]]/ {next}
                /^\[[0-9]+\.[0-9]+ms\]/ {next}
                /^\[rows:[0-9]+\]/ {next}
                /^SELECT.*FROM/ {next}
                /^INSERT INTO/ {next}
                /^UPDATE.*SET/ {next}
                /^DELETE FROM/ {next}
                /record not found/ {next}
                /^\{"level":/ {next}
                /^\{"ts":/ {next}
                /^[[:space:]]*$/ {next}
                {print}
            ' "$tmp_output"
            rm -f "$tmp_output"
            echo ""
            return 1
        fi
    fi
}

echo "[1/$(( ${#SELECTED_MODULES[@]} + 1 ))] 准备测试环境..."
cd "$PROJECT_ROOT"

echo "当前目录: $(pwd)"
echo "Go 版本: $(go version 2>/dev/null || echo '未检测到 go')"
echo "模块列表: ${SELECTED_MODULES[*]}"
echo ""

echo "[2/${#SELECTED_MODULES[@]}] 启动顺序测试..."

for i in "${!SELECTED_MODULES[@]}"; do
    module="${SELECTED_MODULES[$i]}"
    module_num=$((i + 1))

    echo -e "${BLUE}执行 $module ($module_num/${#SELECTED_MODULES[@]}) 测试...${NC}"

    if run_module_tests "$module"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "${RED}测试失败，停止执行后续模块测试${NC}"
        break
    fi

    echo ""
done

echo -e "${BLUE}所有测试执行完成！${NC}"
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              测试总结"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$GENERATE_COVERAGE" == true ]]; then
    echo -e "${BLUE}覆盖率报告：${NC}"
    for result in "${COVERAGE_RESULTS[@]}"; do
        echo "  $result"
    done
    echo ""
fi

echo "测试结果:"
echo -e "  通过模块: ${GREEN}${PASSED_TESTS}${NC}"
echo -e "  失败模块: ${RED}${FAILED_TESTS}${NC}"
echo "  总模块数: ${#SELECTED_MODULES[@]}"
echo ""

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${GREEN}✅ 所有单元测试通过！${NC}"
    if [[ "$GENERATE_COVERAGE" == true ]]; then
        echo ""
        echo "覆盖率报告位置:"
        echo "  目录: $COVERAGE_DIR"
        echo "  查看报告: open $COVERAGE_DIR/*.html"
    fi
    exit 0
else
    echo -e "${RED}❌ 部分单元测试失败，请检查上述输出${NC}"
    exit 1
fi
MTK_EOF_scripts_run_tests_sh_
  mkdir -p "$(dirname "$DEST/scripts/ui.sh")"
  cat > "$DEST/scripts/ui.sh" <<'MTK_EOF_scripts_ui_sh_'
#!/bin/bash
# make-toolkit UI 组件库 — 纯 bash,零依赖,兼容 bash 3.2(不使用关联数组)。
# 三级颜色降级:truecolor / ansi8 / none。被 common.sh source,也被 install.sh 内联。

[[ -n "${MTK_UI_LOADED:-}" ]] && return 0 2>/dev/null
MTK_UI_LOADED=1

MTK_COLOR_MODE=""
C_RESET=""; C_BOLD=""; C_DIM=""
C_ACCENT=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUTED=""
ICON_INFO="[INFO]"; ICON_OK="[OK]"; ICON_WARN="[WARN]"; ICON_ERR="[ERROR]"; ICON_STAGE="-"

# 判定颜色模式并填充颜色/图标变量。
ui_init_colors() {
    if [[ "${MTK_NO_COLOR:-0}" == "1" || -n "${NO_COLOR+x}" || "${TERM:-dumb}" == "dumb" || ! -t 1 ]]; then
        MTK_COLOR_MODE="none"
    elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        MTK_COLOR_MODE="truecolor"
    else
        MTK_COLOR_MODE="ansi8"
    fi

    if [[ "$MTK_COLOR_MODE" == "none" ]]; then
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_ACCENT=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUTED=""
        ICON_INFO="[INFO]"; ICON_OK="[OK]"; ICON_WARN="[WARN]"; ICON_ERR="[ERROR]"; ICON_STAGE="-"
        return 0
    fi

    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    ICON_INFO="i"; ICON_OK="OK"; ICON_WARN="!"; ICON_ERR="x"; ICON_STAGE=">"
    if [[ "$MTK_COLOR_MODE" == "truecolor" ]]; then
        C_ACCENT=$'\033[38;2;0;191;165m'
        C_INFO=$'\033[38;2;136;146;176m'
        C_OK=$'\033[38;2;0;200;120m'
        C_WARN=$'\033[38;2;255;176;32m'
        C_ERR=$'\033[38;2;230;57;70m'
        C_MUTED=$'\033[38;2;120;130;150m'
    else
        C_ACCENT=$'\033[36m'; C_INFO=$'\033[34m'; C_OK=$'\033[32m'
        C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_MUTED=$'\033[2m'
    fi
}

ui_info()    { printf '%s%s%s %s\n' "$C_INFO"   "$ICON_INFO"  "$C_RESET" "$*"; }
ui_success() { printf '%s%s%s %s\n' "$C_OK"     "$ICON_OK"    "$C_RESET" "$*"; }
ui_warn()    { printf '%s%s%s %s\n' "$C_WARN"   "$ICON_WARN"  "$C_RESET" "$*" >&2; }
ui_error()   { printf '%s%s%s %s\n' "$C_ERR"    "$ICON_ERR"   "$C_RESET" "$*" >&2; }
ui_stage()   { printf '%s%s%s %s\n' "$C_ACCENT" "$ICON_STAGE" "$C_RESET" "$*"; }

ui_section() {
    printf '\n%s%s%s%s\n' "$C_BOLD" "$C_ACCENT" "$*" "$C_RESET"
    printf '%s%s%s\n' "$C_MUTED" "----------------------------------------" "$C_RESET"
}

# ui_kv KEY VALUE — 键左对齐到 14 列。
ui_kv() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }

# ui_panel — 从 stdin 读多行,加左边框(none 模式两空格缩进)。
ui_panel() {
    local line
    while IFS= read -r line; do
        if [[ "$MTK_COLOR_MODE" == "none" ]]; then
            printf '  %s\n' "$line"
        else
            printf '%s|%s %s\n' "$C_MUTED" "$C_RESET" "$line"
        fi
    done
}

ui_banner() {
    if [[ "$MTK_COLOR_MODE" == "none" ]]; then
        printf 'make-toolkit -- Go 代码质量工具链\n'
        return 0
    fi
    printf '\n%s%s make-toolkit %s%s\n' "$C_BOLD$C_ACCENT" "###" "###" "$C_RESET"
    printf '%sGo 代码质量工具链%s\n' "$C_MUTED" "$C_RESET"
}

# run_with_spinner DESC -- CMD...
# tty 下转圈;none/非 tty 打印 "DESC... done|failed"。捕获退出码,失败回显输出。
run_with_spinner() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    local tmp rc; tmp="$(mktemp)"
    if [[ "$MTK_COLOR_MODE" == "none" || ! -t 1 ]]; then
        printf '%s... ' "$desc"
        "$@" >"$tmp" 2>&1 &
        wait $! && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then printf 'done\n'; else printf 'failed\n'; cat "$tmp"; fi
        rm -f "$tmp"; return $rc
    fi
    local frames='|/-\' i=0 pid
    "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s%s%s %s' "$C_ACCENT" "${frames:$i:1}" "$C_RESET" "$desc"
        i=$(( (i + 1) % 4 ))
        sleep 0.1
    done
    wait "$pid" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '\r%s%s%s %s\n' "$C_OK" "$ICON_OK" "$C_RESET" "$desc"
    else
        printf '\r%s%s%s %s\n' "$C_ERR" "$ICON_ERR" "$C_RESET" "$desc"; cat "$tmp"
    fi
    rm -f "$tmp"; return $rc
}

export MTK_COLOR_MODE C_RESET C_BOLD C_DIM C_ACCENT C_INFO C_OK C_WARN C_ERR C_MUTED
export ICON_INFO ICON_OK ICON_WARN ICON_ERR ICON_STAGE
export -f ui_init_colors ui_info ui_success ui_warn ui_error ui_stage ui_section ui_kv ui_panel ui_banner run_with_spinner 2>/dev/null || true
MTK_EOF_scripts_ui_sh_
  mkdir -p "$(dirname "$DEST/scripts/vuln-scan.sh")"
  cat > "$DEST/scripts/vuln-scan.sh" <<'MTK_EOF_scripts_vuln_scan_sh_'
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

    # 拼接参数（本机 / 容器分别用绝对路径与 /src 前缀）
    local NATIVE_ARGS="" DOCKER_ARGS=""
    local r
    for r in "${skip_rel[@]}"; do
        NATIVE_ARGS+=" --skip-dirs ${PROJECT_ROOT}/${r}"
        DOCKER_ARGS+=" --skip-dirs /src/${r}"
    done
    for r in "${skip_files_rel[@]}"; do
        NATIVE_ARGS+=" --skip-files ${PROJECT_ROOT}/${r}"
        DOCKER_ARGS+=" --skip-files /src/${r}"
    done

    local scan_rc=0
    if command -v trivy >/dev/null 2>&1; then
        log_info "使用本机 Trivy 扫描"
        set +e
        trivy fs --scanners ${scanners} --no-progress --ignore-unfixed --exit-code 1 --severity ${severity} \
            --cache-dir "$trivy_cache_dir" \
            ${NATIVE_ARGS} \
            "${PROJECT_ROOT}"
        scan_rc=$?
        set -e
    elif command -v docker >/dev/null 2>&1; then
        local trivy_image="${TRIVY_IMAGE:-aquasec/trivy:latest}"
        log_info "使用 Trivy 容器扫描 (${trivy_image})"
        set +e
        docker run --rm -v "${PROJECT_ROOT}:/src" -w /src ${trivy_image} \
            fs --scanners ${scanners} --no-progress --ignore-unfixed --exit-code 1 --severity ${severity} \
            ${DOCKER_ARGS} \
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
MTK_EOF_scripts_vuln_scan_sh_
}

# ===== main =====
ui_init_colors
# 刷新旧式颜色别名(内联 common.sh 的快照早于 ui_init_colors;此处用真实值覆盖)
RED=$C_ERR; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO; CYAN=$C_ACCENT; NC=$C_RESET
trap 'rc=$?; ui_error "安装中断(退出码 $rc)"; exit $rc' ERR
ui_banner
[[ "$SKIP_DOCTOR" == "1" ]] || mtk_doctor
mtk_show_plan "$TARGET" "$DEST" "$VENDOR_SUBDIR"
run_with_spinner "拷贝工具链文件" -- vendor_files
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true
mtk_link_makefile "$TARGET" "$VENDOR_SUBDIR"
mtk_update_gitignore "$TARGET"
mtk_show_result "$TARGET"
