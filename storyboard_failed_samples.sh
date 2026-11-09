#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
BASE="$HOME/AnimeAI/migration_staging/AnimeAI_B"
LAB="$BASE/storyboard_retry_dev/storyboard_fix_lab"
command -v termux-share >/dev/null 2>&1 || { echo "缺少 termux-share"; exit 2; }
PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "缺少 python/python3"; exit 2; }
[ -d "$BASE" ] || { echo "AnimeAI_B目录不存在: $BASE"; exit 2; }
mkdir -p "$LAB/diagnostics"
REPORT="$LAB/diagnostics/storyboard_failed_samples_$(date +%Y%m%d_%H%M%S).txt"
"$PY" - "$BASE" "$REPORT" <<'PY'
import os,sys,json,re,hashlib
base,report=sys.argv[1:]
out=[]
def add(s=""): out.append(str(s))
def short(x,n=900):
    if isinstance(x,str): return x[:n]+("…[截断]" if len(x)>n else "")
    try: return json.dumps(x,ensure_ascii=False)[:n]
    except: return str(x)[:n]
json_files=[]; text_files=[]
for root,dirs,files in os.walk(base):
    dirs[:]=[d for d in dirs if d not in {".git","__pycache__",".venv","venv","node_modules"}]
    for fn in files:
        p=os.path.join(root,fn); ext=os.path.splitext(fn)[1].lower()
        try: size=os.path.getsize(p)
        except OSError: continue
        if size>8_000_000: continue
        if ext==".json": json_files.append(p)
        elif ext in (".txt",".log",".md"): text_files.append(p)
json_files.sort(); text_files.sort()
add("AnimeAI_B 三轮分镜失败样本提取")
add("范围: "+base)
add("只读；不修改源码、不调用模型。")
add("JSON文件总数: "+str(len(json_files))+"；文本/日志文件总数: "+str(len(text_files)))
add()
add("===== 1. 可能的三轮验收JSON =====")
terms=("attempt","program_check","storyboard","分镜","result","check")
ranked=sorted(json_files,key=lambda p:(not any(t in os.path.basename(p).lower() for t in terms),len(p)))
selected=[]
for p in ranked:
    try:
        raw=open(p,"rb").read()
        obj=json.loads(raw.decode("utf-8-sig"))
    except Exception: continue
    name=os.path.basename(p).lower()
    # 只列出命名相关文件，或内容看起来是验收结果的JSON
    dump=short(obj,3000)
    relevant=any(t in name for t in terms) or any(k in dump for k in ("FAIL","分镜动作/画面/声音依据","required_fixes","approved"))
    if relevant: selected.append((p,obj,len(raw)))
add("相关JSON数: "+str(len(selected)))
for p,obj,size in selected[:18]:
    add("--- "+os.path.relpath(p,base)+f" | {size} bytes ---")
    if isinstance(obj,dict):
        for k,v in obj.items():
            ks=str(k).lower()
            if any(t in ks for t in ("story","shot","分镜","result","check","fail","error","output","content","response","attempt","script","issue","fix","approved","status")):
                add(str(k)+": "+short(v,1100))
        # if none of the keys were useful, show compact top-level object
        if not any(any(t in str(k).lower() for t in ("story","shot","分镜","result","check","fail","error","output","content","response","attempt","script","issue","fix","approved","status")) for k in obj):
            add(short(obj,1800))
    else: add(short(obj,1800))
add()
add("===== 2. 文本日志中的失败证据及上下文 =====")
needles=("分镜动作/画面/声音依据","动作无原文依据","画面含原文未出现事实","声音无原文依据","发现原文没有的动作","发现原文没有的画面事实","FAIL")
found=0
for p in text_files:
    try: lines=open(p,encoding="utf-8",errors="replace").read().splitlines()
    except: continue
    matches=[i for i,line in enumerate(lines) if any(n in line for n in needles)]
    if not matches: continue
    add("--- "+os.path.relpath(p,base)+" ---")
    used=set()
    for i in matches[:5]:
        for j in range(max(0,i-2),min(len(lines),i+4)):
            if j not in used:
                add(f"{j+1}: {lines[j][:260]}"); used.add(j)
    found+=1
    if found>=12: break
if not found: add("未在文本/日志中找到上述失败关键词。")
add()
add("===== 3. 分镜正文文件候选 =====")
candidates=[]
for p in text_files:
    try:
        s=open(p,encoding="utf-8",errors="replace").read()
    except: continue
    if ("镜头" in s and ("对应原文事件" in s or "画面：" in s or "动作：" in s)):
        candidates.append((p,s))
add("正文候选数: "+str(len(candidates)))
for p,s in candidates[:8]:
    add("--- "+os.path.relpath(p,base)+f" | {len(s)} chars ---")
    add(short(s,1800))
add()
add("===== 4. 完整报告说明 =====")
add("本地完整报告保存在此文件。若相关JSON没有被列出，表示本轮扫描未识别到可解析且相关的JSON，不代表历史结果必然不存在。")
full="\n".join(out)+"\n"
open(report,"w",encoding="utf-8").write(full)
# 分享版优先保留JSON和正文；过长时截取开头及末尾说明
limit=11500
share=full if len(full)<=limit else full[:limit]+"\n[分享版达到长度上限；本机完整报告保留]\n"
print("本地完整报告:",report)
print("完整报告字符数:",len(full),"分享字符数:",len(share))
open(report+".share","w",encoding="utf-8").write(share)
PY
cat "$REPORT.share" | termux-share -a send -c text/plain
