#!/usr/bin/env bash
# make-toolkit 冒烟测试:在临时 Go 项目上完整走一遍安装器与主要 make 目标。
# 本地与 CI 同一入口:bash tests/smoke.sh
# 兼容 bash 3.2(macOS 系统 bash)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 跑一个 make 目标,失败时回显完整输出
run_make() {
    local desc="$1"; shift
    local log="$TMP/make.log"
    if make -C "$PROJ" "$@" >"$log" 2>&1; then
        pass "$desc"
    else
        echo "---- $desc 失败,输出如下 ----" >&2
        cat "$log" >&2
        fail "$desc"
    fi
}

# ---- 0. 生成器同步:install.sh 必须与源文件一致 ----
mkdir -p "$TMP/sync"
cp "$ROOT/quality.mk" "$ROOT/build-installer.sh" "$TMP/sync/"
cp -R "$ROOT/scripts" "$ROOT/installer" "$TMP/sync/"
bash "$TMP/sync/build-installer.sh" >/dev/null
diff "$ROOT/install.sh" "$TMP/sync/install.sh" >/dev/null \
    || fail "install.sh 与源文件不同步,请重跑 bash build-installer.sh 并提交"
pass "install.sh 与源文件同步"

# ---- 1. 准备临时 Go 项目 ----
PROJ="$TMP/proj"
mkdir -p "$PROJ/pkg/calc"
cat > "$PROJ/go.mod" <<'EOF'
module example.com/smoke

go 1.21
EOF
cat > "$PROJ/pkg/calc/calc.go" <<'EOF'
package calc

// Add 返回 a+b。
func Add(a, b int) int { return a + b }
EOF
cat > "$PROJ/pkg/calc/calc_test.go" <<'EOF'
package calc

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatalf("Add(1,2) = %d, want 3", Add(1, 2))
	}
}
EOF

# ---- 2. 安装(文件参数模式,含 doctor) ----
bash "$ROOT/install.sh" --no-color "$PROJ" >/dev/null
test -f "$PROJ/make-toolkit/quality.mk" || fail "quality.mk 未拷贝"
test -x "$PROJ/make-toolkit/scripts/common.sh" || fail "scripts 未拷贝或缺执行位"
grep -qF "include make-toolkit/quality.mk" "$PROJ/Makefile" || fail "Makefile 未接线"
grep -qxF "coverage_results/" "$PROJ/.gitignore" || fail ".gitignore 未追加 coverage_results/"
grep -qxF ".build-cache/" "$PROJ/.gitignore" || fail ".gitignore 未追加 .build-cache/"
pass "安装器基本安装"

# ---- 3. 幂等:重复安装不重复接线 ----
bash "$ROOT/install.sh" --no-color --skip-doctor "$PROJ" >/dev/null
[ "$(grep -cF 'include make-toolkit/quality.mk' "$PROJ/Makefile")" = 1 ] \
    || fail "重复安装导致 Makefile include 重复"
[ "$(grep -cxF 'coverage_results/' "$PROJ/.gitignore")" = 1 ] \
    || fail "重复安装导致 .gitignore 条目重复"
pass "重复安装幂等"

# ---- 4. 管道模式(等价 curl | bash) ----
PROJ2="$TMP/proj2"
mkdir -p "$PROJ2"
bash -s -- --no-color --skip-doctor "$PROJ2" < "$ROOT/install.sh" >/dev/null
test -f "$PROJ2/make-toolkit/quality.mk" || fail "管道(stdin)安装失败"
pass "管道(stdin)安装"

# ---- 5. 安装器拒绝越界 vendor 目录 ----
UNSAFE_PROJ="$TMP/unsafe"
mkdir -p "$UNSAFE_PROJ"
if bash "$ROOT/install.sh" --no-color --skip-doctor --into ../outside "$UNSAFE_PROJ" >"$TMP/unsafe.log" 2>&1; then
    fail "安装器允许 --into ../outside 写出目标项目"
fi
test ! -e "$TMP/outside" || fail "安装器越界创建了目标项目外目录"
pass "安装器拒绝越界 --into"

# ---- 6. DRY_RUN=1 不应修改文件 ----
cat > "$PROJ/pkg/calc/calc.go" <<'EOF'
package calc
func Add(a,b int)int{return a+b}
EOF
before_dry_run="$(cksum "$PROJ/pkg/calc/calc.go")"
run_make "make format(DRY_RUN=1 不改文件)" format DRY_RUN=1 SKIP_MODERNIZE=1
after_dry_run="$(cksum "$PROJ/pkg/calc/calc.go")"
[[ "$before_dry_run" == "$after_dry_run" ]] || fail "DRY_RUN=1 修改了源文件"
pass "DRY_RUN=1 不修改文件"

# ---- 7. make 目标实跑 ----
run_make "make tk-help" tk-help
# modernize 走 go run gopls@latest 过重,冒烟跳过;gofumpt/goimports 缺失时脚本自动 go install
run_make "make format(SKIP_MODERNIZE=1)" format SKIP_MODERNIZE=1
# golangci-lint 完整安装耗时过长,冒烟只验证 go vet 路径
run_make "make quality-check(go vet 路径)" quality-check DISABLE_GOLANGCI_LINT=1
run_make "make test" test
run_make "make test-coverage" test-coverage
ls "$PROJ"/coverage_results/*_coverage.out >/dev/null 2>&1 || fail "覆盖率文件未生成"
pass "覆盖率产物存在"
run_make "make race-check" race-check
run_make "make cloc" cloc
run_make "make scan(SKIP_VULN=1 开关路径)" scan SKIP_VULN=1

# ---- 8. Docker Trivy 回退复用项目缓存 ----
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$DOCKER_ARGS_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/docker"
DOCKER_ARGS_LOG="$TMP/docker-args.log" \
PATH="$FAKEBIN:/usr/bin:/bin" \
PROJECT_ROOT="$PROJ" \
bash "$PROJ/make-toolkit/scripts/vuln-scan.sh" >/dev/null
grep -qF "$PROJ/.build-cache/trivy" "$TMP/docker-args.log" \
    || fail "Docker Trivy 回退未挂载 .build-cache/trivy"
pass "Docker Trivy 回退挂载缓存"

# ---- 9. 失败路径:测试失败须非零退出码,且过滤后保留 FAIL 信息 ----
cat > "$PROJ/pkg/calc/fail_test.go" <<'EOF'
package calc

import "testing"

func TestIntentionalFailure(t *testing.T) { t.Fatal("intentional failure") }
EOF
if make -C "$PROJ" test >"$TMP/fail.log" 2>&1; then
    fail "存在失败测试时 make test 退出码仍为 0"
fi
grep -q -- "--- FAIL" "$TMP/fail.log" || fail "失败输出经噪声过滤后未保留 FAIL 信息"
rm -f "$PROJ/pkg/calc/fail_test.go"
pass "make test 失败路径(非零退出码 + 保留 FAIL)"

echo ""
echo "全部冒烟测试通过"
