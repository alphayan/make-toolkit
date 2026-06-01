# make-toolkit 安装器升级 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 make-toolkit 的 `install.sh` 升级到 openclaw 品质(纯 bash 彩色 UI + 装前自检 + 计划/结果面板),并让 `make` 运行时共用同一套 UI,保持 Go-only、vendor-into-project、零远程依赖。

**Architecture:** 新增 `scripts/ui.sh`(纯 bash UI 原语,被 `common.sh` source、随 vendor 进用户项目);`common.sh` 加载 ui.sh 并新增工具清单数组(单一事实来源);新增 `installer/body.sh`(安装器专用逻辑,doctor/计划/接线/结果,仅供内联,不 vendor);`build-installer.sh` 把 `ui.sh`+`common.sh`+`body.sh` 就地嵌入 `install.sh` 顶部,再用 `vendor_files()` 写文件,尾部跑主流程。

**Tech Stack:** Bash(兼容 macOS 自带 3.2,**禁用关联数组**),GNU/BSD 通用命令,无外部二进制依赖。

**Spec:** `docs/superpowers/specs/2026-06-02-installer-upgrade-design.md`

**约定:** 所有 git 命令用 `git -C /Users/a/work/make-toolkit ...`(单条命令,不触发审批)。所有验证命令在仓库根 `/Users/a/work/make-toolkit` 下执行。验证一律用一次性命令(不在仓库留测试文件——固化测试属方案 C,非本次范围)。每个任务跑通验证后立即 commit。

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `scripts/ui.sh` | UI 原语:颜色检测/降级、状态行、section/kv/panel/banner/spinner | 新增 |
| `scripts/common.sh` | 加载 ui.sh;工具清单 `MTK_GO_TOOLS`/`MTK_SYS_TOOLS`(单一来源);`log_*` 转调 `ui_*` | 改 |
| `installer/body.sh` | 安装器逻辑:`mtk_pkg_hint`/`mtk_doctor`/`mtk_show_plan`/`mtk_link_makefile`/`mtk_update_gitignore`/`mtk_show_result` | 新增(不 vendor) |
| `build-installer.sh` | 生成 install.sh:嵌入 ui+common+body、`vendor_files()`、尾部主流程 | 改 |
| `install.sh` | 生成产物 | 重新生成 |
| `README.md` | 安装说明 + 自检/降级/参数 | 改 |

---

## Task 1: `scripts/ui.sh` — UI 原语库

**Files:**
- Create: `scripts/ui.sh`

- [ ] **Step 1: 写验证命令并运行,确认当前失败**

Run:
```bash
bash -c 'source scripts/ui.sh; ui_init_colors; ui_info hi' 2>&1
```
Expected: FAIL —— `scripts/ui.sh: No such file or directory`。

- [ ] **Step 2: 创建 `scripts/ui.sh`**

```bash
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
    if [[ "${MTK_NO_COLOR:-0}" == "1" || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" || ! -t 1 ]]; then
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
        if "$@" >"$tmp" 2>&1; then printf 'done\n'; rc=0
        else printf 'failed\n'; cat "$tmp"; rc=1; fi
        rm -f "$tmp"; return $rc
    fi
    local frames='|/-\' i=0 pid
    "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf '\r%s%s%s %s' "$C_ACCENT" "${frames:$i:1}" "$C_RESET" "$desc"
        sleep 0.1
    done
    wait "$pid"; rc=$?
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
```

- [ ] **Step 3: 运行验证(降级 + 函数可用 + bash 3.2)**

Run:
```bash
# 1) 管道(非 tty)天然降级为 none,且无 ESC 转义残留
bash -c 'source scripts/ui.sh; ui_init_colors; ui_info hi; echo "mode=$MTK_COLOR_MODE"' | cat -v
```
Expected: 输出 `[INFO] hi` 与 `mode=none`,**不含** `^[[`(无 ESC)。

```bash
# 2) NO_COLOR 强制 none
bash -c 'NO_COLOR=1 bash -c "source scripts/ui.sh; ui_init_colors; echo \$MTK_COLOR_MODE"'
```
Expected: `none`。

```bash
# 3) section/kv/panel 不报错
bash -c 'source scripts/ui.sh; ui_init_colors; ui_section 标题; ui_kv 键 值; printf "a\nb\n" | ui_panel'
```
Expected: 三行/缩进正常输出,退出码 0。

```bash
# 4) spinner 在非 tty 下 done/failed
bash -c 'source scripts/ui.sh; ui_init_colors; run_with_spinner 测试 -- true; run_with_spinner 应失败 -- false' 2>&1
```
Expected: `测试... done` 与 `应失败... failed`,后者回显空输出。

```bash
# 5) macOS 自带 bash 3.2 无语法错(若存在)
[ -x /bin/bash ] && /bin/bash -n scripts/ui.sh && echo "3.2 syntax OK"
```
Expected: `3.2 syntax OK`(或在非 macOS 上跳过)。

- [ ] **Step 4: Commit**

```bash
git -C /Users/a/work/make-toolkit add scripts/ui.sh
git -C /Users/a/work/make-toolkit commit -m "feat(ui): add pure-bash UI primitives with 3-level color fallback"
```

---

## Task 2: `scripts/common.sh` — 加载 UI + 工具清单 + log 转调

**Files:**
- Modify: `scripts/common.sh`

- [ ] **Step 1: 写验证命令并运行,确认当前状态(数组尚不存在)**

Run:
```bash
bash -c 'source scripts/common.sh; echo "tools=${#MTK_GO_TOOLS[@]}"' 2>&1
```
Expected: 报错或 `tools=0`(`MTK_GO_TOOLS` 未定义)——这是改造前的预期。

- [ ] **Step 2: 替换 `common.sh` 顶部颜色/日志段为加载 ui.sh + 工具清单**

把文件开头到 `log_step` 定义结束(原第 7–36 行,即 `set -e` 到 `log_step() {...}` 那段)替换为:

```bash
set -e

# 加载 UI 原语(同目录)。内嵌进 install.sh 时此文件不存在,守卫跳过,
# 复用已就地定义的 ui_*;作为 vendor 文件时正常 source。
_MK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo .)"
if [[ -f "$_MK_DIR/ui.sh" ]]; then
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
```

> 说明:`RED/GREEN/...` 等旧颜色变量删除(改由 ui.sh 提供 `C_*`);若其它脚本直接引用过 `RED` 等(grep 确认),保留兼容别名。下一步验证会暴露遗漏。

- [ ] **Step 3: 确认没有脚本依赖被删的旧颜色变量**

Run:
```bash
grep -nE '\$\{?(RED|GREEN|YELLOW|BLUE|CYAN|NC)\b' scripts/*.sh | grep -v 'scripts/common.sh' || echo "无外部引用,安全"
```
Expected: `无外部引用,安全`。若有输出,在 `common.sh` 末尾补:`RED=$C_ERR; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO; CYAN=$C_ACCENT; NC=$C_RESET`(并 `export` 之),再重跑。

- [ ] **Step 4: 运行验证(清单可用 + 日志可用 + 旧版 bash)**

Run:
```bash
bash -c 'source scripts/ui.sh; source scripts/common.sh;
  echo "go_tools=${#MTK_GO_TOOLS[@]} sys_tools=${#MTK_SYS_TOOLS[@]}";
  log_info 兼容;
  IFS="|" read -r b m v d <<<"${MTK_GO_TOOLS[2]}"; echo "module=$m"' 2>&1
```
Expected: `go_tools=4 sys_tools=2`、一行 `[INFO] 兼容`(或带色)、最后一行 `module=github.com/golangci/golangci-lint/cmd/golangci-lint`。

```bash
[ -x /bin/bash ] && /bin/bash -n scripts/common.sh && echo "3.2 syntax OK"
```
Expected: `3.2 syntax OK`。

- [ ] **Step 5: Commit**

```bash
git -C /Users/a/work/make-toolkit add scripts/common.sh
git -C /Users/a/work/make-toolkit commit -m "feat(common): load ui.sh, add single-source tool manifest, route log_* to ui_*"
```

---

## Task 3: `installer/body.sh` — 安装器逻辑

**Files:**
- Create: `installer/body.sh`

- [ ] **Step 1: 写验证命令并运行,确认当前失败**

Run:
```bash
bash -c 'source scripts/ui.sh; source scripts/common.sh; source installer/body.sh; type mtk_doctor' 2>&1
```
Expected: FAIL —— `installer/body.sh: No such file or directory`。

- [ ] **Step 2: 创建 `installer/body.sh`**

```bash
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
    local target="$1" gi="$target/.gitignore" pat
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
```

- [ ] **Step 3: 运行验证(doctor 分类 + 接线幂等 + 旧版 bash)**

Run:
```bash
# doctor:把 PATH 清空使所有工具"缺失",检查分级输出与 MTK_MISSING
bash -c 'set -euo pipefail; source scripts/ui.sh; source scripts/common.sh; source installer/body.sh;
  PATH=/nonexistent mtk_doctor; echo "missing=${MTK_MISSING[*]:-none}"' 2>&1 | tail -12
```
Expected: 出现 `go 缺失`、`gofumpt 缺失(... go install mvdan.cc/gofumpt@latest)`、`trivy 缺失(...)`、`cloc 未安装(可选...)`,末行 `missing=` 含 `go make gofumpt ... trivy cloc`。

```bash
# 接线幂等:临时项目跑两次,include 只出现一次
bash -c 'set -e; source scripts/ui.sh; source scripts/common.sh; source installer/body.sh;
  d="$(mktemp -d)"; mtk_link_makefile "$d" make-toolkit; mtk_link_makefile "$d" make-toolkit;
  n=$(grep -c "include make-toolkit/quality.mk" "$d/Makefile"); echo "include_count=$n"; rm -rf "$d"'
```
Expected: `include_count=1`。

```bash
[ -x /bin/bash ] && /bin/bash -n installer/body.sh && echo "3.2 syntax OK"
```
Expected: `3.2 syntax OK`。

- [ ] **Step 4: Commit**

```bash
git -C /Users/a/work/make-toolkit add installer/body.sh
git -C /Users/a/work/make-toolkit commit -m "feat(installer): add body.sh (doctor/plan/link/result) for inlining"
```

---

## Task 4: `build-installer.sh` — 新生成结构

**Files:**
- Modify: `build-installer.sh`

- [ ] **Step 1: 用新版本整体替换 `build-installer.sh`**

```bash
#!/usr/bin/env bash
# 生成自包含安装器 install.sh:把 ui.sh + common.sh + installer/body.sh 就地嵌入,
# 并把 quality.mk + scripts/*.sh 内联为 vendor_files()。
# 改了源文件后重跑本脚本即可重新生成 install.sh(唯一事实来源是仓库里的源文件)。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SRC/install.sh"

[[ -f "$SRC/quality.mk" && -d "$SRC/scripts" && -f "$SRC/scripts/ui.sh" && -f "$SRC/installer/body.sh" ]] \
  || { echo "源不完整:需 quality.mk / scripts/ui.sh / installer/body.sh" >&2; exit 1; }

# 1) 头部:参数解析、目标解析
cat > "$OUT" <<'HEADER'
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
HEADER

# 2) 就地嵌入 ui.sh + common.sh + body.sh(函数/数组即时可用,先于写文件)
{
  echo ""
  echo "# ===== embedded: scripts/ui.sh ====="
  cat "$SRC/scripts/ui.sh"
  echo ""
  echo "# ===== embedded: scripts/common.sh ====="
  cat "$SRC/scripts/common.sh"
  echo ""
  echo "# ===== embedded: installer/body.sh ====="
  cat "$SRC/installer/body.sh"
  echo ""
} >> "$OUT"

# 3) vendor_files():把要拷进用户项目的文件写入 DEST
echo "" >> "$OUT"
echo "# ===== vendored files (written into target project) =====" >> "$OUT"
echo "vendor_files() {" >> "$OUT"
echo '  mkdir -p "$DEST/scripts"' >> "$OUT"
emit() {
  local rel="$1" src="$2"
  local marker="MTK_EOF_$(echo "$rel" | tr -c 'A-Za-z0-9' '_')"
  {
    echo "  mkdir -p \"\$(dirname \"\$DEST/$rel\")\""
    echo "  cat > \"\$DEST/$rel\" <<'$marker'"
    cat "$src"
    echo "$marker"
  } >> "$OUT"
}
emit "quality.mk" "$SRC/quality.mk"
for f in "$SRC"/scripts/*.sh; do
  emit "scripts/$(basename "$f")" "$f"
done
echo "}" >> "$OUT"

# 4) 尾部:主流程
cat >> "$OUT" <<'FOOTER'

# ===== main =====
ui_init_colors
trap 'rc=$?; ui_error "安装中断(退出码 $rc)"; exit $rc' ERR
ui_banner
[[ "$SKIP_DOCTOR" == "1" ]] || mtk_doctor
mtk_show_plan "$TARGET" "$DEST" "$VENDOR_SUBDIR"
run_with_spinner "拷贝工具链文件" -- vendor_files
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true
mtk_link_makefile "$TARGET" "$VENDOR_SUBDIR"
mtk_update_gitignore "$TARGET"
mtk_show_result "$TARGET"
FOOTER

chmod +x "$OUT"
echo "已生成 $OUT ($(wc -l < "$OUT" | tr -d ' ') 行)"
```

- [ ] **Step 2: 运行 build-installer,生成 install.sh**

Run:
```bash
bash build-installer.sh
```
Expected: `已生成 .../install.sh (NNNN 行)`,NNNN 远大于原 1361(因新增嵌入)。

- [ ] **Step 3: 语法检查 + 关键标记 grep**

Run:
```bash
bash -n install.sh && echo "syntax OK"
[ -x /bin/bash ] && /bin/bash -n install.sh && echo "3.2 syntax OK"
grep -cE 'vendor_files\(\)|mtk_doctor|ui_init_colors|MTK_GO_TOOLS' install.sh
```
Expected: `syntax OK`、`3.2 syntax OK`、计数 ≥ 4(各标记至少出现一次)。

- [ ] **Step 4: Commit(含重新生成的 install.sh)**

```bash
git -C /Users/a/work/make-toolkit add build-installer.sh install.sh
git -C /Users/a/work/make-toolkit commit -m "feat(installer): regenerate install.sh with embedded UI + doctor + plan"
```

---

## Task 5: 端到端验证矩阵(spec §10)

**Files:**
- 无新增(仅验证;若发现 bug,回到对应任务修复并重跑 `bash build-installer.sh` 后再提交)

- [ ] **Step 1: 空目录安装 → 新建 Makefile 并接入**

Run:
```bash
D="$(mktemp -d)"; printf 'module demo\n\ngo 1.22\n' > "$D/go.mod"
bash install.sh "$D" >/tmp/mtk_e2e.log 2>&1; echo "rc=$?"
grep -q 'include make-toolkit/quality.mk' "$D/Makefile" && echo "Makefile OK"
[ -f "$D/make-toolkit/scripts/ui.sh" ] && [ -f "$D/make-toolkit/quality.mk" ] && echo "vendored OK"
```
Expected: `rc=0`、`Makefile OK`、`vendored OK`。

- [ ] **Step 2: 已有 Makefile → 追加,不破坏原目标**

Run:
```bash
printf 'build:\n\tgo build ./...\n' > "$D/Makefile"
bash install.sh "$D" >>/tmp/mtk_e2e.log 2>&1
grep -q '^build:' "$D/Makefile" && grep -q 'include make-toolkit/quality.mk' "$D/Makefile" && echo "append OK"
```
Expected: `append OK`。

- [ ] **Step 3: 重复运行幂等**

Run:
```bash
bash install.sh "$D" >>/tmp/mtk_e2e.log 2>&1
n=$(grep -c 'include make-toolkit/quality.mk' "$D/Makefile"); echo "include_count=$n"
g=$(grep -c 'coverage_results/' "$D/.gitignore"); echo "gitignore_count=$g"
```
Expected: `include_count=1`、`gitignore_count=1`。

- [ ] **Step 4: 非 tty / NO_COLOR 降级无转义残留**

Run:
```bash
bash install.sh "$D" 2>&1 | cat -v | grep -c '\^\[\[' 
NO_COLOR=1 bash install.sh "$D" >/tmp/mtk_nc.log 2>&1; cat -v /tmp/mtk_nc.log | grep -c '\^\[\['
```
Expected: 两次都是 `0`(管道与 NO_COLOR 下无 ESC 序列)。

- [ ] **Step 5: 缺工具时 doctor 命令正确**

Run:
```bash
PATH="/usr/bin:/bin" bash install.sh "$D" 2>&1 | grep -E 'go install (mvdan.cc/gofumpt|golang.org/x/vuln)' | head -2
```
Expected: 至少一行精确的 `go install mvdan.cc/gofumpt@latest`(若该机恰好装了全部 Go 工具,临时 `PATH` 仍含其安装目录则可能为空——此时改用 `PATH=/nonexistent` 跑 `mtk_doctor` 单测,见 Task 3 Step 3)。

- [ ] **Step 6: 装完工具链可用(make 运行时共用新 UI)**

Run(需本机有 `go`、`make`):
```bash
make -C "$D" tk-help >/tmp/mtk_help.log 2>&1; echo "rc=$?"; head -3 /tmp/mtk_help.log
make -C "$D" cloc >/tmp/mtk_cloc.log 2>&1; echo "cloc_rc=$?"
rm -rf "$D"
```
Expected: `tk-help` `rc=0` 且打印目标帮助;`cloc` 退出码 0(有 cloc 则统计,无则文件计数回退)。

- [ ] **Step 7: 记录结果(无代码改动则不提交)**

若全部通过,本任务无文件变更、跳过 commit。若某步暴露 bug:回到对应源文件修复 → `bash build-installer.sh` → 重跑该步 → 在那个任务下提交修复。

---

## Task 6: `README.md` — 更新安装说明

**Files:**
- Modify: `README.md`(「安装 / 方式一」段,原约 27–44 行)

- [ ] **Step 1: 替换「方式一:vendor 安装器」小节正文**

把「### 方式一:vendor 安装器(推荐,零外部依赖)」标题之后、到「### 方式二」之前的正文,替换为:

```markdown
把工具链**拷贝**进项目、随项目自身仓库提交,不依赖任何远程仓库——个人 / 公司项目都安全自包含:

```bash
# install.sh 是自包含单文件,可拷到任何机器 / 项目直接运行
bash install.sh /path/to/your-project     # 省略目标则为当前目录
bash install.sh --into tools/mtk DIR       # 自定义 vendor 子目录(默认 make-toolkit)
bash install.sh --no-color DIR             # 关闭彩色输出(CI / 重定向自动也会降级)
bash install.sh --skip-doctor DIR          # 跳过装前环境自检
```

运行时它会:

1. **装前自检(doctor)**:检测 `go`/`make`、Go 系工具(gofumpt/goimports/golangci-lint/govulncheck)、系统工具(trivy/cloc),缺啥**只报告 + 给出可复制的安装命令**——不碰你的系统、不需 sudo。缺的 Go 工具在你跑 `make` 时会自动 `go install` 兜底。
2. **拷贝**:把 `quality.mk` + `scripts/`(含共享 UI 库 `ui.sh`)拷进 `your-project/make-toolkit/`。
3. **接线**:在项目 `Makefile` 接入 `include make-toolkit/quality.mk`(无 Makefile 则新建,已有则在末尾追加标记块、不动你原有目标)。
4. **忽略生成物**:把 `coverage_results/`、`.build-cache/` 加进 `.gitignore`。

可重复运行以更新脚本(幂等)。彩色输出在非 TTY、`NO_COLOR`、`TERM=dumb` 或 `--no-color` 下自动降级为纯文本。

> `install.sh` 由 `build-installer.sh` 从本仓库源文件(`scripts/ui.sh` + `scripts/common.sh` + `installer/body.sh` + `quality.mk` + `scripts/*.sh`)生成;改了源文件后重跑 `bash build-installer.sh` 重新打包即可。
```

- [ ] **Step 2: 验证 README 渲染无破损**

Run:
```bash
grep -n 'skip-doctor\|装前自检\|ui.sh' README.md | head
```
Expected: 命中新增的若干行。

- [ ] **Step 3: Commit**

```bash
git -C /Users/a/work/make-toolkit add README.md
git -C /Users/a/work/make-toolkit commit -m "docs: document doctor, color fallback, and new install flags"
```

---

## 完成标准

- 6 个任务全部 commit;`feat/installer-upgrade` 分支上 `install.sh` 为重新生成的产物。
- 端到端矩阵(Task 5)全绿。
- `bash -n` 与 `/bin/bash -n`(若有)对 `ui.sh`/`common.sh`/`body.sh`/`install.sh` 均通过。
- 收尾可用 superpowers:finishing-a-development-branch 决定合并 / PR。
