# 示例：消费方项目根目录的 Makefile
#
# 第一步：用安装器把工具包 vendor 到当前项目（一次性，可重复运行以更新）
#     curl -fsSL https://raw.githubusercontent.com/alphayan/make-toolkit/refs/heads/main/install.sh | bash
#
# 第二步：照下面写你的 Makefile。
# ───────────────────────────────────────────────────────────────

# 【最简】单模块项目（项目根就有 go.mod）：无需任何配置，自动发现即可。
#     include make-toolkit/quality.mk

# 【多模块工作区】显式声明模块目录与友好别名：
GO_MODULES     := svc-api svc-admin svc-shared
MODULE_ALIASES := api=svc-api admin=svc-admin shared=svc-shared
VULN_SEVERITY  := CRITICAL,HIGH

include make-toolkit/quality.mk

# 你自己的目标照常写（勿与工具包目标重名：
# format/quality-check/scan/lint/test/test-verbose/test-coverage/race-check/cloc）
.PHONY: build run
build:
	go build ./...

run:
	go run ./...

# 用法示例：
#   make scan                      # 前后端依赖漏洞扫描
#   make format                    # 格式化全部模块
#   make test                      # 测试全部模块
#   make test TEST_MODULES=api     # 仅测 api（经别名 → svc-api）
#   make test TEST_MODULES="api admin"
#   make lint                      # quality-check + scan
#   SKIP_VULN=1 make lint          # 跳过漏洞扫描
