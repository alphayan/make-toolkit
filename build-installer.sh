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

# 2) 就地嵌入 ui.sh + common.sh + body.sh(去 shebang;函数/数组即时可用,先于写文件)
{
  echo ""
  echo "# ===== embedded: scripts/ui.sh ====="
  tail -n +2 "$SRC/scripts/ui.sh"
  echo ""
  echo "# ===== embedded: scripts/common.sh ====="
  tail -n +2 "$SRC/scripts/common.sh"
  echo ""
  echo "# ===== embedded: installer/body.sh ====="
  tail -n +2 "$SRC/installer/body.sh"
  echo ""
} >> "$OUT"

# 3) vendor_files():把要拷进用户项目的文件写入 DEST
echo "" >> "$OUT"
echo "# ===== vendored files (written into target project) =====" >> "$OUT"
echo "vendor_files() {" >> "$OUT"
echo '  mkdir -p "$DEST/scripts"' >> "$OUT"
emit() {
  local rel="$1" src="$2"
  # 注:echo 末尾换行经 tr 变为 marker 尾部 '_';勿改成 printf '%s' 否则标记不一致
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
FOOTER

bash -n "$OUT" || { echo "生成的 install.sh 语法有误,生成中止" >&2; exit 1; }
chmod +x "$OUT"
echo "已生成 $OUT ($(wc -l < "$OUT" | tr -d ' ') 行)"
