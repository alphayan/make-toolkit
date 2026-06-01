# make-toolkit

可复用的 **Go 代码质量工具链**，以一个可被 `include` 的 `Makefile` 片段 + 一组脚本的形式提供。
由一套多模块 Go 项目里那套「漏洞检查 + 代码格式化 + 测试」通用化而来——把硬编码的模块名抽成配置，
并支持自动发现 `go.mod`，因此**任何 Go 项目都能引入复用**。

## 提供的能力（`make` 目标）

| 目标 | 说明 |
| --- | --- |
| `make format` | gofumpt + goimports + modernize 格式化（按模块并发） |
| `make quality-check` | go vet + golangci-lint（含 staticcheck/ineffassign 等） |
| `make scan` | **依赖漏洞扫描**：后端 Go `govulncheck` + 前端/整仓 `Trivy` |
| `make lint` | `quality-check` + `scan` |
| `make test` | 单元测试（`make test TEST_MODULES="a b"` 指定模块） |
| `make test-verbose` | 单元测试，详细输出 |
| `make test-coverage` | 单元测试 + 覆盖率报告（`coverage_results/`） |
| `make race-check` | `go test -race` |
| `make cloc` | 代码行数统计（`WITH_TESTS=1` 含测试文件） |
| `make tk-help` | 打印以上帮助 |

> **范围说明**：本工具包只收录**可移植的代码质量**部分。原 Makefile 里的
> `build` / `service-*` / `clean-*` / `health-check` 等强依赖其 docker-compose 与容器命名，
> 不可移植，**未收录**；`race-check` 也只保留了 `go test -race` 核心，去掉了原版基于
> docker-compose 的并发压测与日志巡检。

## 安装

### 方式一：vendor 安装器（推荐，零外部依赖）

安装器会把工具链**拷贝**进项目、随项目自身仓库提交；安装完成后不依赖任何远程仓库，个人 / 公司项目都安全自包含：

```bash
# 从 GitHub 直接安装到当前目录
curl -fsSL https://raw.githubusercontent.com/alphayan/make-toolkit/refs/heads/main/install.sh | bash

# 从 GitHub 直接安装到指定项目
curl -fsSL https://raw.githubusercontent.com/alphayan/make-toolkit/refs/heads/main/install.sh | bash -s -- /path/to/your-project

# 自定义 vendor 子目录（默认 make-toolkit）
curl -fsSL https://raw.githubusercontent.com/alphayan/make-toolkit/refs/heads/main/install.sh | bash -s -- --into tools/mtk /path/to/your-project
```

如果想先审阅安装器，也可以下载后再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/alphayan/make-toolkit/refs/heads/main/install.sh
bash install.sh /path/to/your-project
bash install.sh --no-color /path/to/your-project       # 关闭彩色输出（CI / 重定向自动也会降级）
bash install.sh --skip-doctor /path/to/your-project    # 跳过装前环境自检
```

运行时它会：

1. **装前自检（doctor）**：检测 `go`/`make`、Go 系工具（gofumpt/goimports/golangci-lint/govulncheck）、系统工具（trivy/cloc），缺啥**只报告 + 给出可复制的安装命令**——不碰你的系统、不需 sudo。缺的 Go 工具在你跑 `make` 时会自动 `go install` 兜底。
2. **拷贝**：把 `quality.mk` + `scripts/`（含共享 UI 库 `ui.sh`）拷进 `your-project/make-toolkit/`。
3. **接线**：在项目 `Makefile` 接入 `include make-toolkit/quality.mk`（无 Makefile 则新建，已有则在末尾追加标记块、不动你原有目标）。
4. **忽略生成物**：把 `coverage_results/`、`.build-cache/` 加进 `.gitignore`。

可重复运行以更新脚本（幂等）。彩色输出在非 TTY、`NO_COLOR`、`TERM=dumb` 或 `--no-color` 下自动降级为纯文本。

> `install.sh` 由 `build-installer.sh` 从本仓库源文件（`scripts/ui.sh` + `scripts/common.sh` + `installer/body.sh` + `quality.mk` + `scripts/*.sh`）生成；改了源文件后重跑 `bash build-installer.sh` 重新打包即可。

### 方式二：Git submodule（团队共享单一来源时）

```bash
git submodule add https://github.com/alphayan/make-toolkit.git tools/make-toolkit
```
```makefile
GO_MODULES := svc-a svc-b      # 留空则自动发现 go.mod
include tools/make-toolkit/quality.mk
```

### 装好之后

```bash
make scan     # 前后端依赖漏洞扫描
make format   # 格式化
make test     # 测试
make lint     # quality-check + scan
```
完整示例见 [`examples/Makefile`](examples/Makefile)。

## 模块发现：零配置 or 显式

- **不配置**：脚本自动查找所有 `go.mod`（排除 `vendor/node_modules/.git/dist/testdata`），
  把它们的目录作为模块。单模块项目（根目录就有 `go.mod`）开箱即用。
- **显式**：设 `GO_MODULES`（空格或逗号分隔的子目录），适合多模块工作区或只想检查部分模块。

## 配置变量（`include` 之前覆盖，或 `make X VAR=...`）

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `GO_MODULES` | 自动发现 | Go 模块目录列表（format/quality-check/scan/test/race 通用） |
| `FORMAT_MODULES` | = `GO_MODULES` | 仅覆盖格式化的模块列表 |
| `TEST_MODULES` | = `GO_MODULES` | 仅覆盖测试的模块列表 |
| `MODULE_ALIASES` | 空 | 测试友好别名，如 `api=svc-api admin=svc-admin` |
| `COVERAGE_EXCLUDE` | `/main$\|/cmd\|/docs` | 测试时排除的包路径正则 |
| `VULN_SEVERITY` | `CRITICAL,HIGH` | Trivy 严重级别过滤 |
| `TRIVY_SCANNERS` | `vuln` | Trivy 扫描器，可加 `secret`、`misconfig` |
| `TRIVY_SKIP_DIRS` | 空 | 额外跳过的目录（已默认跳过 node_modules/dist/vendor/.git） |
| `TRIVY_IMAGE` | `aquasec/trivy:latest` | 无本机 trivy 时的 Docker 回退镜像 |
| `RACE_TIMEOUT` | `5m` | race 单包超时 |
| `RACE_EXCLUDE` | `e2e\|docs` | race 排除的包路径正则 |
| `GOLANGCI_TIMEOUT` | `5m` | golangci-lint 超时 |

**开关**：`SKIP_VULN=1`（跳过漏洞扫描）、`SKIP_CHECKS=1`（跳过质量检查）、
`DISABLE_GOLANGCI_LINT=1`、`SKIP_MODERNIZE=1`（格式化时跳过风格升级）。

## `make scan` 做了什么

1. **后端 Go（govulncheck）**：对每个模块 `govulncheck ./...`；未装会尝试 `go install`。
2. **前端 + 整仓（Trivy）**：对项目根 `trivy fs`，覆盖前端 `package.json`/lockfile 等所有依赖清单；
   默认 `--severity CRITICAL,HIGH --ignore-unfixed`，自动跳过 node_modules/dist/vendor/.git 及密钥类文件；
   无本机 `trivy` 时回退到 Docker 镜像。

任一发现漏洞即退出码非 0。

## 依赖工具

- **Go**（govulncheck/go vet/go test 必需）；`govulncheck`、`gofumpt`、`goimports`、`golangci-lint` 缺失时脚本会尝试 `go install`。
- **Trivy**：`brew install trivy`，或装 Docker 用容器回退（都没有则跳过 Trivy 那步）。
- **cloc**（可选）：`brew install cloc`；缺失时 `make cloc` 退化为文件计数。
- golangci-lint 读取**消费方项目自己的** `.golangci.yml`。

## 不用 make 也能跑

脚本可直接执行，用 `PROJECT_ROOT` 指定项目根：
```bash
PROJECT_ROOT=/path/to/project GO_MODULES="api admin" bash tools/make-toolkit/scripts/vuln-scan.sh
```

## 来源

通用化自一套多模块 Go 项目 `deploy/scripts/` 下的 `common.sh` / `vuln-scan.sh` / `format-code.sh` /
`quality-check.sh` / `run-tests.sh` / `race-check.sh`。
