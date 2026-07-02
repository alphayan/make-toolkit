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
        GO_FILES=$(count -name "*.go" ! -name "*_test.go")
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
