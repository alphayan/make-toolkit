#!/usr/bin/env bash
# 生成自包含安装器 install.sh：把 quality.mk + scripts/*.sh 内联进单个脚本。
# 改了源文件后重跑本脚本即可重新生成 install.sh（唯一事实来源是仓库里的源文件）。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SRC/install.sh"

[[ -f "$SRC/quality.mk" && -d "$SRC/scripts" ]] || { echo "源不完整：缺 quality.mk / scripts/" >&2; exit 1; }

# 1) 头部：参数解析、目标解析、DEST 准备
cat > "$OUT" <<'HEADER'
#!/usr/bin/env bash
# make-toolkit 自包含安装器（由 build-installer.sh 自动生成，请勿手改）
#
# 把 Go 代码质量工具链拷贝进目标项目并接好 Makefile：
#   make scan / format / quality-check / lint / test / test-coverage / race-check / cloc
# 不用 git submodule、不依赖任何远程仓库 —— 拷进去的文件随项目自身仓库提交即可，
# 个人 / 公司项目都安全自包含。
#
# 用法:
#   bash install.sh [目标项目目录]        # 默认当前目录
#   bash install.sh --into deps/mtk DIR   # 自定义 vendor 子目录（默认 make-toolkit）
#   bash install.sh --help
set -euo pipefail

VENDOR_SUBDIR="make-toolkit"
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --into) VENDOR_SUBDIR="${2:?--into 需要一个目录名}"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
make-toolkit 安装器
  bash install.sh [目标项目目录]        默认当前目录
  bash install.sh --into deps/mtk DIR   自定义 vendor 子目录
拷贝 quality.mk + scripts/ 进目标项目的 <子目录>/，并在其 Makefile 接入
`include <子目录>/quality.mk`。可重复运行以更新脚本。
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

echo "→ 安装 make-toolkit 到: $DEST"
mkdir -p "$DEST/scripts"
# ===== BEGIN embedded files =====
HEADER

# 2) 内联各文件（带引号的 heredoc，原样写出，不做任何展开）
emit() {
  local rel="$1" src="$2"
  local marker="MTK_EOF_$(echo "$rel" | tr -c 'A-Za-z0-9' '_')"
  {
    echo "mkdir -p \"\$(dirname \"\$DEST/$rel\")\""
    echo "cat > \"\$DEST/$rel\" <<'$marker'"
    cat "$src"
    echo "$marker"
  } >> "$OUT"
}

emit "quality.mk" "$SRC/quality.mk"
for f in "$SRC"/scripts/*.sh; do
  emit "scripts/$(basename "$f")" "$f"
done

# 3) 尾部：可执行位、接 Makefile、忽略生成物
cat >> "$OUT" <<'FOOTER'
# ===== END embedded files =====
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true

MK="$TARGET/Makefile"
INCLUDE_LINE="include ${VENDOR_SUBDIR}/quality.mk"
if [[ ! -f "$MK" ]]; then
  {
    echo "# >>> make-toolkit >>>"
    echo "# 留空则自动发现 go.mod；多模块可显式声明，例如："
    echo "# GO_MODULES := svc-a svc-b"
    echo "$INCLUDE_LINE"
    echo "# <<< make-toolkit <<<"
  } > "$MK"
  echo "→ 已创建 Makefile 并接入工具链"
elif grep -qF "$INCLUDE_LINE" "$MK"; then
  echo "→ Makefile 已包含 include（脚本已刷新），跳过接线"
else
  {
    echo ""
    echo "# >>> make-toolkit >>>"
    echo "$INCLUDE_LINE"
    echo "# <<< make-toolkit <<<"
  } >> "$MK"
  echo "→ 已向现有 Makefile 追加 include"
fi

GI="$TARGET/.gitignore"
for pat in "coverage_results/" ".build-cache/"; do
  if [[ ! -f "$GI" ]] || ! grep -qxF "$pat" "$GI" 2>/dev/null; then
    echo "$pat" >> "$GI"
  fi
done

echo "✓ 完成。下一步： (cd \"$TARGET\" && make tk-help)"
FOOTER

chmod +x "$OUT"
echo "已生成 $OUT ($(wc -l < "$OUT" | tr -d ' ') 行)"
