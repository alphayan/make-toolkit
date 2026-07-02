# make-toolkit — 可复用的 Go 代码质量工具链
#
# 用法：安装器会把本文件拷进目标项目；在项目根目录的 Makefile 里 include：
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
QUALITY_EXCLUDE  ?= e2e|docs
VULN_SEVERITY    ?= CRITICAL,HIGH
TRIVY_SCANNERS   ?= vuln
TRIVY_SKIP_DIRS  ?=
RACE_TIMEOUT     ?= 5m
RACE_EXCLUDE     ?= e2e|docs
GOLANGCI_TIMEOUT ?= 5m
TEST_TIMEOUT     ?= 10m
TEST_PARALLEL    ?= 1

# 导出给脚本（未赋值的导出为空字符串，脚本内有默认值，无副作用）
export PROJECT_ROOT GO_MODULES FORMAT_MODULES TEST_MODULES MODULE_ALIASES COVERAGE_EXCLUDE
export QUALITY_EXCLUDE VULN_SEVERITY TRIVY_SCANNERS TRIVY_SKIP_DIRS TRIVY_IMAGE
export RACE_TIMEOUT RACE_EXCLUDE RACE_MODULES
export GOLANGCI_TIMEOUT GOLANGCI_LINT_VERSION TEST_TIMEOUT TEST_PARALLEL MODERNIZE_VERSION
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
	@echo "  QUALITY_EXCLUDE VULN_SEVERITY TRIVY_SCANNERS TRIVY_SKIP_DIRS"
	@echo "  TEST_TIMEOUT TEST_PARALLEL GOLANGCI_LINT_VERSION MODERNIZE_VERSION"
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
