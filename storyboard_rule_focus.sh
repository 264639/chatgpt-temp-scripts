#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
WORK="$HOME/AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev"
SRC="$WORK/short_drama_pipeline_v32.py"
LAB="$WORK/storyboard_fix_lab"
[ -f "$SRC" ] || { echo "源码不存在: $SRC"; exit 2; }
PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "缺少 python/python3"; exit 2; }
command -v termux-share >/dev/null 2>&1 || { echo "缺少 termux-share"; exit 2; }
mkdir -p "$LAB/diagnostics"
REPORT="$LAB/diagnostics/storyboard_rule_focus_$(date +%Y%m%d_%H%M%S).txt"
"$PY" - "$SRC" "$LAB" "$REPORT" <<'PY'
import sys, os, glob, hashlib, json
src, lab, report = sys.argv[1:]
lines=open(src,encoding="utf-8").read().splitlines()
out=[]
def add(s=""): out.append(str(s))
def section(title): add(); add("===== "+title+" =====")
add("AnimeAI_B 分镜规则定点审查")
add("源码SHA256: "+hashlib.sha256(open(src,"rb").read()).hexdigest())
add("源码: "+src)
add("只读；不改源码、不调用模型。")
section("A. _generic_storyboard_checks 与 storyboard_checks（源码第406-515行）")
for n in range(405, min(515,len(lines))):
    s=lines[n]
    if len(s)>210: s=s[:207]+"..."
    add(f"{n+1}: {s}")
section("B. 分镜提示词（第923-976行）")
for n in range(922, min(976,len(lines))):
    s=lines[n]
    if len(s)>180: s=s[:177]+"..."
    add(f"{n+1}: {s}")
section("C. 自动寻找真实验收记录")
patterns=[
 os.path.join(lab,"**","program_check_attempt_*.json"),
 os.path.join(lab,"**","*attempt*.json"),
 os.path.join(lab,"**","*program_check*.json"),
]
found=[]
for pat in patterns:
    for p in glob.glob(pat,recursive=True):
        if os.path.isfile(p) and p not in found: found.append(p)
found.sort()
add("找到候选JSON数量: "+str(len(found)))
for p in found[:8]:
    add("--- "+p+" ---")
    try:
        obj=json.load(open(p,encoding="utf-8"))
        s=json.dumps(obj,ensure_ascii=False,separators=(",",":"))
        add(s[:900]+("...[截断]" if len(s)>900 else ""))
    except Exception as e:
        add("读取失败: "+repr(e))
if len(found)>8: add("其余文件省略: "+str(len(found)-8))
section("D. 项目结果目录中含失败信息的日志候选")
candidates=[]
for root,dirs,files in os.walk(os.path.join(lab,"projects")):
    dirs[:] = dirs[:]
    for fn in files:
        if fn.lower().endswith((".txt",".log",".json")) and any(k in fn.lower() for k in ("check","attempt","result","report","storyboard")):
            candidates.append(os.path.join(root,fn))
add("日志候选数: "+str(len(candidates)))
for p in candidates[:12]:
    try:
        data=open(p,encoding="utf-8",errors="replace").read()
        keys=("动作无原文依据","画面","声音无原文依据","FAIL","分镜动作/画面/声音依据")
        snippets=[]
        ls=data.splitlines()
        for i,line in enumerate(ls):
            if any(k in line for k in keys):
                snippets.append(f"{i+1}: {line[:220]}")
                if len(snippets)>=3: break
        if snippets:
            add("--- "+p+" ---")
            for x in snippets: add(x)
    except Exception: pass
add()
add("结论边界：本次只提取规则源码、提示词和本机实际存在的记录；不会把缺失路径当作测试记录不存在。")
text="\n".join(out)+"\n"
limit=8200
if len(text)>limit:
    text=text[:limit]+"\n[达到分享长度上限；本机报告保留完整已提取内容]\n"
open(report,"w",encoding="utf-8").write(text)
print("报告字符数:",len(text))
print("报告路径:",report)
PY
cat "$REPORT" | termux-share -a send -c text/plain
