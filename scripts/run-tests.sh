#!/bin/bash

# 统一单元测试脚本（通用化）
# 运行各 Go 模块的单元测试，支持覆盖率报告。
# 模块来自命令行参数 / TEST_MODULES / GO_MODULES，留空则自动发现 go.mod。
#
# 通用化配置：
#   MODULE_ALIASES   形如 "api=svc-api admin=svc-admin" 的别名映射（空格分隔，可选）
#   COVERAGE_EXCLUDE 覆盖率/测试包排除正则（默认 '/main$|/cmd|/docs'）
#   TEST_TIMEOUT     go test 超时（默认 10m）
#   TEST_PARALLEL    go test -parallel 并行度（默认 1，兼容依赖串行的存量项目）

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
GENERATE_COVERAGE=false
: "${TEST_TIMEOUT:=10m}"
: "${TEST_PARALLEL:=1}"

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

    # 用数组承载命令，逐个参数原样传给 go，绝不经过 shell 二次解析。
    # 历史实现把包路径/覆盖率文件名拼成字符串后 eval，导致恶意目录名
    # （如 "$(touch x)"）或含空格/元字符的路径被当作命令执行（命令注入）。
    local go_test_cmd=(go test "-timeout=${TEST_TIMEOUT}" "-parallel=${TEST_PARALLEL}")
    for pkg in "${packages_array[@]}"; do
        go_test_cmd+=("$pkg")
    done

    if [[ "$SHORT_MODE" == true ]]; then
        go_test_cmd+=(-short)
    fi

    if [[ "$GENERATE_COVERAGE" == true ]]; then
        # 文件名安全化：根模块 "." 会产生以点开头的隐藏文件，改用 root
        local module_slug="${module//\//_}"
        [[ "$module_slug" == "." ]] && module_slug="root"
        tmp_coverage="$COVERAGE_DIR/${module_slug}_coverage.out"
        go_test_cmd+=("-coverprofile=$tmp_coverage")
    fi

    # verbose 直接输出；否则捕获到临时文件，仅失败时过滤噪声后回显
    local rc=0
    if [[ "$VERBOSE_MODE" == true ]]; then
        "${go_test_cmd[@]}" || rc=$?
    else
        "${go_test_cmd[@]}" > "$tmp_output" 2>&1 || rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}✓ $module 测试通过${NC}"
        if [[ "$GENERATE_COVERAGE" == true ]] && [ -f "$tmp_coverage" ]; then
            local coverage
            coverage=$(go tool cover -func="$tmp_coverage" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "0%")
            echo -e "  覆盖率: ${YELLOW}$coverage${NC}"
            COVERAGE_RESULTS+=("$module: $coverage")
            local html_file="$COVERAGE_DIR/${module_slug}_coverage.html"
            go tool cover -html="$tmp_coverage" -o="$html_file" 2>/dev/null || true
            echo -e "  HTML 报告: $html_file"
        fi
    else
        echo -e "${RED}✗ $module 测试失败${NC}"
        if [[ "$VERBOSE_MODE" != true ]]; then
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
        fi
    fi
    rm -f "$tmp_output"
    echo ""
    return $rc
}

echo "[1/2] 准备测试环境..."
cd "$PROJECT_ROOT"

echo "当前目录: $(pwd)"
echo "Go 版本: $(go version 2>/dev/null || echo '未检测到 go')"
echo "模块列表: ${SELECTED_MODULES[*]}"
echo ""

echo "[2/2] 启动顺序测试..."

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
