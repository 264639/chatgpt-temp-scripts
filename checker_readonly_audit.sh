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

echo "===== 完整报告已保存 ====="
echo "$REPORT"

# 生成短版分享摘要；完整报告仍保留在原路径
SUMMARY="${REPORT%.txt}_分享摘要.txt"
python - "$SRC" "$RESULT" "$REPORT" "$SUMMARY" "$EXPECTED_SHA" <<'PY'
import ast, json, os, re, sys
src, result_dir, report, summary, expected = sys.argv[1:]
out = []
def add(s=""):
    out.append(str(s))
actual = __import__("hashlib").sha256(open(src,"rb").read()).hexdigest()
add("===== AnimeAI_B 分镜验收器只读审查摘要 =====")
add("源码SHA256: " + actual)
add("预期SHA256: " + expected)
add("源码版本核对: " + ("一致" if actual == expected else "不一致"))
add("源码行数: " + str(sum(1 for _ in open(src,encoding="utf-8"))))
add("完整报告: " + report)
add()
add("===== 相关函数/类（名称与行号） =====")
tree = ast.parse(open(src,encoding="utf-8").read())
keys = ("storyboard","check","valid","audit","event")
nodes = [n for n in ast.walk(tree) if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and any(k in n.name.lower() for k in keys)]
for n in sorted(nodes,key=lambda x:x.lineno):
    add(f"{n.name}: 第{n.lineno}-{getattr(n,'end_lineno',n.lineno)}行")
if not nodes: add("未找到匹配定义")
add()
add("===== 关键规则代码位置（每条限长） =====")
patterns = re.compile(r"动作/画面/声音依据|原文依据|storyboard_checks|forbidden_additions|event_order|连续原文|分镜事件覆盖|画面.*依据|声音.*依据")
hits = []
for i,line in enumerate(open(src,encoding="utf-8"),1):
    if patterns.search(line):
        hits.append(f"{i}: {line.strip()[:180]}")
for line in hits[:18]: add(line)
if len(hits)>18: add(f"其余匹配行省略: {len(hits)-18}条（完整报告中保留上下文）")
add()
add("===== 三轮真实模型验收 JSON 摘要 =====")
for i in range(1,4):
    p=os.path.join(result_dir,"storyboard",f"program_check_attempt_{i}.json")
    add(f"--- 第{i}轮: {p} ---")
    if not os.path.isfile(p):
        add("文件缺失")
        continue
    try:
        obj=json.load(open(p,encoding="utf-8"))
        compact=json.dumps(obj,ensure_ascii=False,separators=(",",":"))
        add(compact[:1500] + ("...[内容截断，完整内容见本地完整报告]" if len(compact)>1500 else ""))
    except Exception as e:
        add("JSON读取失败: "+repr(e))
add()
add("说明: 本摘要为便于分享而压缩；完整报告没有删除。脚本只读，未修改源码、未调用模型。")
data="\n".join(out)+"\n"
if len(data)>8500:
    data=data[:8500]+"\n[摘要达到长度上限，后续内容省略；完整报告仍在本地]\n"
open(summary,"w",encoding="utf-8").write(data)
print("分享摘要字符数:",len(data))
print("分享摘要路径:",summary)
PY

echo "===== 正在分享精简摘要（完整报告保留在本地） ====="
cat "$SUMMARY" | termux-share -a send -c text/plain
