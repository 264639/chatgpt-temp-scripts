#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

WORK="$HOME/AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev"
SRC="$WORK/short_drama_pipeline_v32.py"
LAB="$WORK/storyboard_fix_lab"
RESULT="$LAB/projects/real_model_chenmo_20261109_232548"
EXPECTED_SHA="f1655c78123c8bc3f97338d66e7297a529397e75b94991020604bd7290831ddf"

for cmd in python sha256sum grep cat; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：$cmd"; exit 2; }
done
command -v termux-share >/dev/null 2>&1 || { echo "缺少 termux-share，请先确认 Termux:API 已安装"; exit 2; }
[ -f "$SRC" ] || { echo "找不到源码：$SRC"; exit 2; }

mkdir -p "$LAB/diagnostics"
REPORT="$LAB/diagnostics/checker_readonly_audit_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "===== AnimeAI_B 分镜验收器只读审查 ====="
  echo "时间：$(date '+%F %T %Z')"
  echo "源码：$SRC"
  echo
  echo "===== 一、源码身份 ====="
  sha256sum "$SRC"
  echo "行数：$(wc -l < "$SRC")"
  echo "预期测试 SHA256：$EXPECTED_SHA"
  ACTUAL_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
    echo "源码版本核对：一致"
  else
    echo "源码版本核对：不一致（本脚本仍只读，不会修改源码）"
  fi

  echo
  echo "===== 二、相关函数定义 ====="
  python - "$SRC" <<'PY'
import ast, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    source = f.read()
tree = ast.parse(source)
lines = source.splitlines()
keys = ("storyboard", "check", "valid", "audit", "event")
found = 0
for node in sorted(ast.walk(tree), key=lambda x: getattr(x, "lineno", 0)):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        if any(k in node.name.lower() for k in keys):
            end = getattr(node, "end_lineno", node.lineno)
            print(f"\n[{node.name}] 第{node.lineno}-{end}行")
            print(lines[node.lineno - 1][:500])
            found += 1
if not found:
    print("未找到名称匹配的函数/类")
PY

  echo
  echo "===== 三、验收规则及关键词上下文 ====="
  grep -n -E -C 7 '动作/画面/声音依据|原文依据|storyboard_checks|forbidden_additions|event_order|连续原文|分镜事件覆盖|画面.*依据|声音.*依据' "$SRC" || true

  echo
  echo "===== 四、三轮真实模型验收记录 ====="
  for f in \
    "$RESULT/storyboard/program_check_attempt_1.json" \
    "$RESULT/storyboard/program_check_attempt_2.json" \
    "$RESULT/storyboard/program_check_attempt_3.json"; do
    if [ -f "$f" ]; then
      echo "--- $f ---"
      cat "$f"
    else
      echo "缺少：$f"
    fi
  done

  echo
  echo "===== 五、结束状态 ====="
  echo "本脚本只读检查；未修改源码、未调用模型、未覆盖历史结果。"
  echo "报告路径：$REPORT"
  echo "===== 只读审查结束 ====="
} > "$REPORT" 2>&1

echo "===== 报告生成成功 ====="
echo "$REPORT"
echo "===== 正在打开 Android 分享面板 ====="
cat "$REPORT" | termux-share -a send -c text/plain
