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
