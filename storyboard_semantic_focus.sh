#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
WORK="$HOME/AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev"
SRC="$WORK/short_drama_pipeline_v32.py"
LAB="$WORK/storyboard_fix_lab"
PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "缺少 python/python3"; exit 2; }
command -v termux-share >/dev/null 2>&1 || { echo "缺少 termux-share"; exit 2; }
[ -f "$SRC" ] || { echo "源码不存在"; exit 2; }
mkdir -p "$LAB/diagnostics"
REPORT="$LAB/diagnostics/storyboard_semantic_focus_$(date +%Y%m%d_%H%M%S).txt"
"$PY" - "$SRC" "$WORK" "$REPORT" <<'PY'
import ast,sys,os,glob,json,hashlib
src,work,report=sys.argv[1:]
code=open(src,encoding="utf-8").read()
tree=ast.parse(code)
lines=code.splitlines()
names={"_sound_is_grounded","_compact","_is_known_package","known_case","_generic_storyboard_checks","storyboard_checks","_known_storyboard_prompt","storyboard_prompt"}
out=[]
def add(x=""): out.append(str(x))
add("AnimeAI_B 分镜语义验收定点证据")
add("SHA256: "+hashlib.sha256(open(src,"rb").read()).hexdigest())
add("只读；不修改源码、不调用模型。")
add()
add("===== 1. 关键函数完整源码 =====")
found=set()
for node in sorted((n for n in ast.walk(tree) if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and n.name in names),key=lambda n:n.lineno):
    found.add(node.name)
    add(f"--- {node.name} 第{node.lineno}-{getattr(node,'end_lineno',node.lineno)}行 ---")
    for line in lines[node.lineno-1:getattr(node,'end_lineno',node.lineno)]:
        add(line[:230])
for n in sorted(names-found): add("未找到函数: "+n)
add()
add("===== 2. 相关分镜规则/调用位置 =====")
keys=("storyboard_checks(","_generic_storyboard_checks(","_sound_is_grounded(","storyboard_prompt(","_is_known_package(")
hits=[]
for i,line in enumerate(lines,1):
    if any(k in line for k in keys): hits.append(f"{i}: {line.strip()[:200]}")
for x in hits[:35]: add(x)
add()
add("===== 3. 项目目录内真实分镜结果/验收记录索引 =====")
exts={".json",".txt",".log",".md"}
candidates=[]
for root,dirs,files in os.walk(work):
    dirs[:]=[d for d in dirs if d not in {".git","__pycache__","venv",".venv"}]
    for fn in files:
        p=os.path.join(root,fn)
        if os.path.splitext(fn)[1].lower() in exts:
            try: size=os.path.getsize(p)
            except OSError: continue
            if size<=2_000_000 and any(k in fn.lower() for k in ("storyboard","attempt","check","result","report","分镜","验收")):
                candidates.append(p)
candidates=sorted(set(candidates))
add("候选文件数: "+str(len(candidates)))
for p in candidates[:35]:
    add(f"{os.path.relpath(p,work)} | {os.path.getsize(p)} bytes")
add()
add("===== 4. 真实失败信息摘录（每个文件最多3条） =====")
count=0
for p in candidates:
    if count>=12: break
    try:
        data=open(p,encoding="utf-8",errors="replace").read()
    except Exception: continue
    terms=("动作无原文依据","画面含原文未出现事实","声音无原文依据","分镜动作/画面/声音依据","柜台","记录本","收件人姓名")
    snippets=[]
    for i,line in enumerate(data.splitlines()):
        if any(t in line for t in terms):
            snippets.append(f"{i+1}: {line[:230]}")
            if len(snippets)>=3: break
    if snippets:
        add("--- "+os.path.relpath(p,work)+" ---")
        for s in snippets: add(s)
        count+=1
add()
add("注：本报告优先提取源代码真实判定逻辑与本机可找到的历史产物。没有找到的记录不会被推断为不存在。")
text="\n".join(out)+"\n"
limit=8400
if len(text)>limit: text=text[:limit]+"\n[摘要达到分享上限；完整源码和历史文件均未改动]\n"
open(report,"w",encoding="utf-8").write(text)
print("摘要字符数:",len(text))
print("报告路径:",report)
PY
cat "$REPORT" | termux-share -a send -c text/plain
