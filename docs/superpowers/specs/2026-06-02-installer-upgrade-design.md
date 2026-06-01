# make-toolkit 安装器升级设计(openclaw 品质)

- 日期:2026-06-02
- 状态:已批准(待实现)
- 分支:`feat/installer-upgrade`
- 参考对象:`openclaw/scripts/install.sh`(成熟一键安装器)

## 1. 背景

现有 `install.sh` 由 `build-installer.sh` 用带引号 heredoc 生成,功能正确(拷 `quality.mk`+`scripts/` 进目标项目、接 `Makefile`、补 `.gitignore`、幂等可重跑),但:

- UI 朴素:仅 `echo -e` + `[INFO]/[SUCCESS]` 前缀。
- 无装前环境自检:用户装完才在 `make` 运行时发现缺工具。
- 安装器逻辑埋在 `build-installer.sh` 的 heredoc 里,不易读、不易维护。

参考对象 openclaw 的安装器具备:24-bit 彩色品牌 UI、`uname` 平台检测、依赖自举、spinner/面板、`NO_COLOR`/非交互降级。本设计在**不改变 make-toolkit “vendor 进项目、零远程依赖、不碰系统” 本质**的前提下,把安装体验升级到该品质,并让 `make` 运行时共用同一套 UI。

## 2. 目标 / 非目标

### 目标
1. 纯 bash 彩色 UI(truecolor / 8 色 / 无色 三级降级):spinner、面板、banner。
2. 装前自检(doctor):报告 `go`/`make`、Go 系工具、系统工具的安装情况,缺失项给出可复制的安装命令(只报告、不安装)。
3. `make` 运行时(`format`/`scan`/`test`…)共用同一 UI,整体观感统一。
4. 安装器逻辑从 heredoc 解放成独立源文件,可单独维护。
5. 保持现有 CLI(`[目标目录]`、`--into`)、幂等、vendor 本质。

### 非目标(明确不做)
- 不支持非 Go 语言(多语言扩展属另一个项目)。
- 不做远程 `curl|bash` 分发(无托管地址;保持自包含)。
- 不自动安装任何依赖、不 `sudo`、不碰系统——自检只报告。
- 不引入 `gum` 或任何外部二进制下载。
- 不固化测试脚本(方案 C,留作后续可选)。

## 3. 关键决策(及理由)

| 编号 | 决策 | 理由 |
| --- | --- | --- |
| D1 | 范围 = 只 Go + 保持 vendor 本质 | 用户选定;多语言 / 远程分发各自另开项目。 |
| D2 | 依赖 = 自检 + 引导,不自动装 | 契合“安全自包含、不碰用户机器”;缺的 Go 工具由 `make` 运行时 `ensure_*` / `go install` 兜底(现状已具备)。 |
| D3 | UI = 纯 bash,零下载 | 保持零远程依赖定位;`gum` 会破坏自包含。 |
| D4 | 重构 = 方案 A(共享 UI 层 + 安装器源文件化) | 整套观感统一 + 安装器可维护,改动面可控。 |

## 4. 文件变更清单

| 文件 | 动作 | 说明 |
| --- | --- | --- |
| `scripts/ui.sh` | 新增 | 纯 bash UI 组件库,单一事实来源。**会随 vendor 进用户项目**(因 `common.sh` 依赖它)。 |
| `scripts/common.sh` | 改 | `log_*` 转调 `ui.sh`(签名不变);新增工具清单数据,`ensure_*` 与安装器 doctor 共用。 |
| `installer/body.sh` | 新增 | 安装器主体逻辑(banner / doctor / plan / vendor / 接 Makefile / 补 gitignore / result)。**不进 `scripts/`、不 vendor 给用户**,仅供 `build-installer.sh` 内联。 |
| `build-installer.sh` | 改 | 生成顺序见 §8。 |
| `install.sh` | 重新生成 | 上者产出的单文件自包含产物。 |
| `README.md` | 改 | 更新安装说明 + 自检/降级/参数。 |

## 5. `scripts/ui.sh` 规格(纯 bash,零依赖,bash 3.2 兼容)

### 颜色能力检测 `ui_init_colors`
判定顺序,得出 `truecolor` / `ansi8` / `none` 之一:
- `none` 当:`MTK_NO_COLOR=1`(由 `--no-color` 设置)、或 `NO_COLOR` 非空、或 `TERM=dumb`、或 stdout 非 tty(`[[ ! -t 1 ]]`)。
- `truecolor` 当:上面不成立且 `COLORTERM` ∈ {`truecolor`,`24bit`}。
- 否则 `ansi8`。

`none` 时所有颜色变量置为空串,转义自然消失。品牌色用 24-bit;`ansi8` 退化到基础 8 色近似。

### 组件 API
| 函数 | 行为 | 降级(none) |
| --- | --- | --- |
| `ui_info/ui_warn/ui_success/ui_error MSG` | 带图标状态行 | `[INFO]/[WARN]/[OK]/[ERROR] MSG` |
| `ui_section TITLE` | 分节标题(着色 + 分隔) | 纯文本标题 |
| `ui_stage MSG` | 步骤前缀(如 `▸`) | `- MSG` |
| `ui_kv KEY VALUE` | 左对齐键 + 值 | `KEY: VALUE` |
| `ui_panel`(stdin 多行) | box-drawing 框线面板 | 两空格缩进 |
| `run_with_spinner DESC -- CMD...` | tty 下后台跑命令 + 转圈;捕获 rc 与输出,失败回显 | 打印 `DESC… done` / `DESC… failed` 后回显输出 |
| `ui_banner` | make-toolkit 色块 banner + tagline | 单行纯文本标题 |
| `ui_install_plan` | 安装计划面板(目标目录 / vendor 子目录 / 待拷文件 / Makefile 接线方式 / gitignore 追加项) | 缩进列表 |
| `ui_result` | 结果面板 + 自检摘要(还缺啥)+ 下一步 `cd <target> && make tk-help` | 缩进列表 |

### 兼容
`common.sh` 现有 `log_info/log_success/log_warning/log_error/log_step` 保留为 `ui_*` 的薄包装,运行时脚本零改动。`none` 降级时输出与现状近似。

## 6. `scripts/common.sh` 改动

1. 顶部加载 UI(同目录):
   ```bash
   _MK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   [[ -f "$_MK_DIR/ui.sh" ]] && source "$_MK_DIR/ui.sh"
   ```
   `log_*` 改为转调 `ui_*`;保留 `export -f` 列表(追加新函数)。
2. 新增**工具清单**作为单一事实来源。**bash 3.2 无关联数组**,用 `名称|字段|字段` 分隔字符串数组:
   ```bash
   # binary|module|version|desc
   MTK_GO_TOOLS=(
     "gofumpt|mvdan.cc/gofumpt|latest|格式化"
     "goimports|golang.org/x/tools/cmd/goimports|latest|整理导入"
     "golangci-lint|github.com/golangci/golangci-lint/cmd/golangci-lint|${GOLANGCI_LINT_VERSION:-v1.60.3}|质量检查"
     "govulncheck|golang.org/x/vuln/cmd/govulncheck|latest|漏洞扫描"
   )
   # binary|brew_hint|optional(yes/no)|desc  (linux 提示运行时按发行版拼)
   MTK_SYS_TOOLS=(
     "trivy|brew install trivy|no|整仓/前端漏洞(可 docker 回退)"
     "cloc|brew install cloc|yes|代码行数统计"
   )
   ```
   `MTK_GO_TOOLS` 作为 doctor 的单一来源;现有 `ensure_gofumpt`/`ensure_goimports`/`ensure_golangci_lint` 的硬编码 module 须与清单值一致(本次不重构其内部,避免运行时回归)。
3. `modernize` 经 `go run …/modernize@latest` 按需拉取,无需预装,自检不单列(只要有 `go` 即可)。
4. `staticcheck`/`ineffassign` 由 `golangci-lint` 内置覆盖,自检只看 `golangci-lint`。

## 7. 安装器流程(`installer/body.sh`,内联进 `install.sh`)

参数:`[目标目录]`(默认 `$PWD`)、`--into <子目录>`(默认 `make-toolkit`)、`--no-color`(设 `MTK_NO_COLOR=1`)、`--skip-doctor`、`-h/--help`。无交互点,不引入确认 / `--yes`(符合“参数驱动、无需菜单”)。

主流程顺序:
1. 解析参数 → 计算 `TARGET`、`DEST=$TARGET/$VENDOR_SUBDIR`。
2. `ui_init_colors` → `ui_banner`。
3. **doctor**(`--skip-doctor` 时跳过;只报告,不安装;`uname -s` 判平台):
   - 必需:`go`、`make` — 缺则 `ui_error` 标红(不强制中断 vendor,但提示“装了才有用”)。
   - Go 系(遍历 `MTK_GO_TOOLS`):`command -v` 检测;缺则标 `○ 缺失(make 时自动安装)` + 手动命令 `go install <module>@<version>`。
   - 系统系(遍历 `MTK_SYS_TOOLS`):缺则按平台给命令——macOS → `brew_hint`;Linux → 探测 `apt-get`/`dnf`/`pacman` 给对应 `install` 命令;`trivy` 额外注明可 docker 回退;`cloc` 标“可选”。
4. `ui_install_plan` 面板(纯展示,随后直接执行)。
5. `run_with_spinner "拷贝工具链文件" -- vendor_files`(`vendor_files` 见 §8)→ `chmod +x "$DEST"/scripts/*.sh`。
6. 接 `Makefile`:幂等——含 `include` 跳过 / 无则新建带标记块 / 有则追加带标记块(沿用现有逻辑,输出改 `ui_*`)。
7. 补 `.gitignore`:`coverage_results/`、`.build-cache/`(缺失才加)。
8. `ui_result`:成功 + 自检摘要(还缺哪些工具)+ 下一步提示。

错误处理:`set -euo pipefail`;`trap … ERR` 在非 0 退出时 `ui_error` 打印错误与退出码;`run_with_spinner` 的临时输出文件即时清理,vendor 文件均内联。

## 8. `build-installer.sh` 改动

生成的 `install.sh` 结构(自上而下):
1. **头部 heredoc**:shebang、`set -euo pipefail`、用法、参数解析(含 `--no-color`/`--skip-doctor`)、`TARGET`/`DEST` 计算。
2. **内联 `scripts/ui.sh`**(带引号 heredoc,原样)——使 UI 函数在 install.sh 中就地可用。
3. **内联 `installer/body.sh`**(banner/doctor/plan/result/接线函数)。
4. **`vendor_files()` 函数**:把原 `emit()` 生成的 `cat > "$DEST/..." <<'MARKER'` 写文件命令**包进该函数体**(含 `quality.mk` + `scripts/*.sh`,`ui.sh` 也在其中,会被写入用户项目)。
5. **尾部主流程**:`ui_banner` → doctor → `ui_install_plan` → `run_with_spinner … -- vendor_files` → `chmod` → 接 Makefile → gitignore → `ui_result`。

`emit()` 仅改为把写文件命令收拢进 `vendor_files()`,内联机制(带引号 heredoc、唯一 marker)不变。

## 9. 健壮性 / 安全

`set -euo pipefail`;不删用户文件;`Makefile`/`.gitignore` 仅追加;不 `sudo`、不下载二进制;可重复运行(幂等)。自包含、零远程依赖不变。

## 10. 验证矩阵(本次手动验证;固化为脚本属方案 C)

1. 空目录安装 → 新建 `Makefile` 并接入。
2. 已有 `Makefile` 安装 → 追加标记块,不动原目标。
3. 重复运行 → 显示“已包含,刷新脚本”,幂等。
4. `NO_COLOR=1` 与管道(非 tty)→ 降级纯文本,无转义残留。
5. 缺工具(临时改 PATH)→ doctor 输出的安装命令正确、分类正确。
6. 装完 `make tk-help` / `make format` 跑通,且新 UI 在运行时生效。
7. 在 macOS `/bin/bash`(3.2)下运行安装器不报数组语法错误。

## 11. 交付物

- `scripts/ui.sh`(新)
- `scripts/common.sh`(改)
- `installer/body.sh`(新)
- `build-installer.sh`(改)
- `install.sh`(重新生成)
- `README.md`(改)

## 12. 未来(非本次范围)

- 方案 C:安装器冒烟测试(docker / bats),仿 openclaw `test-install-sh-docker.sh`。
- 远程一键安装(需托管地址)。
- 多语言工具链扩展。
