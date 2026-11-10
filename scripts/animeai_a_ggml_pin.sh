#!/data/data/com.termux/files/usr/bin/bash
# AnimeAI_A only: pin GGML submodule to the verified target commit.
set -Eeuo pipefail

A_ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
MAIN_REPO="$A_ROOT/vendor/stable-diffusion.cpp"
GGML_REPO="$MAIN_REPO/ggml"
MAIN_TARGET="a3c49b13be5a64a0b4da2b576af3a17e8ae1ccbf"
GGML_TARGET="d803c238f67915fb825a9aa4df27b99356d51597"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="$A_ROOT/reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/ANIMEAI_A_GGML_PIN_$STAMP.txt"
exec > >(tee "$REPORT") 2>&1

fail() { echo "RESULT=FAIL"; echo "原因：$*"; exit 1; }
echo "===== AnimeAI_A GGML定点修复 ====="
echo "时间：$(date)"
echo "项目：AnimeAI_A"
echo "主引擎目标：$MAIN_TARGET"
echo "GGML目标：$GGML_TARGET"
echo "保护：不访问 AnimeAI_B / AnimeAI_V50；不修改模型；不清理工作区"

[ -d "$MAIN_REPO/.git" ] || [ -f "$MAIN_REPO/.git" ] || fail "找不到 A 项目的 stable-diffusion.cpp Git 仓库：$MAIN_REPO"
[ -d "$GGML_REPO/.git" ] || [ -f "$GGML_REPO/.git" ] || fail "找不到 GGML 子仓库：$GGML_REPO"

MAIN_HEAD="$(git -C "$MAIN_REPO" rev-parse HEAD)"
echo "主引擎当前：$MAIN_HEAD"
[ "$MAIN_HEAD" = "$MAIN_TARGET" ] || fail "主引擎提交不匹配，拒绝修改 GGML；当前=$MAIN_HEAD"

GGML_HEAD="$(git -C "$GGML_REPO" rev-parse HEAD)"
echo "GGML当前：$GGML_HEAD"
echo "GGML目标：$GGML_TARGET"

if [ "$GGML_HEAD" = "$GGML_TARGET" ]; then
  echo "GGML已处于目标提交，无需重复操作。"
else
  STATUS="$(git -C "$GGML_REPO" status --porcelain=v1 --untracked-files=all)"
  if [ -n "$STATUS" ]; then
    echo "--- 检测到现有工作区修改，先保全到 Git stash（包含删除/新增/未跟踪文件） ---"
    printf '%s\n' "$STATUS"
    BEFORE_STASH="$(git -C "$GGML_REPO" rev-parse -q --verify refs/stash 2>/dev/null || true)"
    git -C "$GGML_REPO" stash push --include-untracked -m "AnimeAI_A_GGML_preserve_before_pin_$STAMP"
    AFTER_STASH="$(git -C "$GGML_REPO" rev-parse -q --verify refs/stash 2>/dev/null || true)"
    [ -n "$AFTER_STASH" ] || fail "工作区修改未能写入 stash，停止切换"
    if [ "$AFTER_STASH" = "$BEFORE_STASH" ] && [ -n "$STATUS" ]; then
      fail "stash 指针未变化，无法证明修改已保全，停止切换"
    fi
    echo "已保全 stash：$AFTER_STASH"
    git -C "$GGML_REPO" status --short
    [ -z "$(git -C "$GGML_REPO" status --porcelain=v1 --untracked-files=all)" ] || fail "stash 后工作区仍不干净，停止切换"
  else
    echo "GGML工作区干净，无需stash。"
  fi

  if ! git -C "$GGML_REPO" cat-file -e "$GGML_TARGET^{commit}" 2>/dev/null; then
    echo "本地缺少目标对象，尝试从原 origin 获取指定提交……"
    git -C "$GGML_REPO" fetch --no-tags origin "$GGML_TARGET"
  fi
  git -C "$GGML_REPO" cat-file -e "$GGML_TARGET^{commit}" 2>/dev/null || fail "目标提交对象不可用；原工作区修改已保存在stash，没有切换"
  git -C "$GGML_REPO" checkout --detach "$GGML_TARGET"
  ACTUAL="$(git -C "$GGML_REPO" rev-parse HEAD)"
  [ "$ACTUAL" = "$GGML_TARGET" ] || fail "GGML提交校验不一致：$ACTUAL"
fi

echo "--- 最终验收 ---"
echo "主引擎：$(git -C "$MAIN_REPO" rev-parse HEAD)"
echo "GGML：$(git -C "$GGML_REPO" rev-parse HEAD)"
echo "GGML工作区："
git -C "$GGML_REPO" status --short --branch
echo "stash保留记录："
git -C "$GGML_REPO" stash list -5 || true
echo "RESULT=SUCCESS"
echo "说明：本脚本只固定 A 项目 GGML 子仓库提交；没有执行编译或声称推理通过。"
echo "报告：$REPORT"
if command -v termux-share >/dev/null 2>&1; then
  cat "$REPORT" | termux-share -a send -c text/plain || echo "分享弹窗未能打开；报告仍保存在：$REPORT"
fi
