#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
BASE="$HOME/AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev"
LAB="$BASE/storyboard_fix_lab"
PY="$(command -v python || command -v python3 || true)"
command -v termux-share >/dev/null 2>&1 || { echo "缺少 termux-share"; exit 2; }
[ -n "$PY" ] || { echo "缺少 python/python3"; exit 2; }
[ -d "$LAB" ] || { echo "实验目录不存在: $LAB"; exit 2; }
mkdir -p "$LAB/diagnostics"
REPORT="$LAB/diagnostics/last_order_three_round_evidence_$(date +%Y%m%d_%H%M%S).txt"
"$PY" - "$BASE" "$LAB" "$REPORT" <<'PY'
import os,sys,json,re,hashlib
base,lab,report=sys.argv[1:]
out=[]
def a(x=""): out.append(str(x))
def clip(s,n=1500):
    if not isinstance(s,str):
        try:s=json.dumps(s,ensure_ascii=False)
        except:s=str(s)
    return s[:n]+("...[截断]" if len(s)>n else "")
files=[]
for root,ds,fs in os.walk(lab):
    ds[:]=[d for d in ds if d not in {".git","__pycache__","venv",".venv"}]
    for fn in fs:
        p=os.path.join(root,fn)
        try: z=os.path.getsize(p)
        except: continue
        if z<=5_000_000 and os.path.splitext(fn)[1].lower() in (".json",".txt",".log",".md"):
            files.append((p,z))
files.sort()
a("《最后一单》三轮分镜证据定点提取")
a("扫描目录: "+lab)
a("候选文本/JSON文件: "+str(len(files)))
a("只读；不修改源码、不调用模型。")
a()
# rank relevant files using filename and content indicators
rank=[]
for p,z in files:
    name=os.path.basename(p).lower()
    score=0
    for k,w in (("attempt",8),("program_check",7),("storyboard",6),("qwen",5),("last_order",10),("lastorder",10),("分镜",6),("result",3),("retry",3)):
        if k in name: score+=w
    try:
        with open(p,encoding="utf-8",errors="replace") as f: s=f.read()
    except: continue
    if "最后一单" in s or "陈墨" in s: score+=12
    if "Qwen3-4B" in s or "qwen3-4b" in s.lower(): score+=5
    if any(k in s for k in ("分镜动作/画面/声音依据","动作无原文依据","画面含原文未出现事实")): score+=7
    if score: rank.append((score,p,z,s))
rank.sort(key=lambda x:(-x[0],x[1]))
a("===== 1. 最相关文件索引 =====")
a("相关文件数: "+str(len(rank)))
for score,p,z,s in rank[:35]:
    a(f"[相关度{score}] {os.path.relpath(p,base)} | {z} bytes")
a()
a("===== 2. 含《最后一单》/陈墨/三轮失败标记的JSON =====")
shown=0
for score,p,z,s in rank:
    if os.path.splitext(p)[1].lower()!=".json": continue
    try: obj=json.loads(s)
    except: continue
    blob=json.dumps(obj,ensure_ascii=False)
    if not any(k in blob for k in ("最后一单","陈墨","动作无原文依据","画面含原文未出现事实","分镜动作/画面/声音依据")) and score<8: continue
    a("--- "+os.path.relpath(p,base)+f" | {z} bytes ---")
    if isinstance(obj,dict):
        for k,v in obj.items():
            if any(t in str(k).lower() for t in ("content","output","response","script","story","shot","result","check","fail","error","attempt","prompt","text")):
                a(str(k)+": "+clip(v,1800))
        if len(out)<5: a(clip(obj,2200))
    else: a(clip(obj,2600))
    shown+=1
    if shown>=8: break
if not shown: a("本实验目录内未找到可解析且命中的目标JSON。")
a()
a("===== 3. 最相关日志/正文中的具体失败行 =====")
need=("最后一单","陈墨","动作无原文依据","画面含原文未出现事实","分镜动作/画面/声音依据","柜台前","手持手机","记录本")
count=0
for score,p,z,s in rank:
    if os.path.splitext(p)[1].lower()==".json": continue
    lines=s.splitlines()
    matches=[i for i,l in enumerate(lines) if any(k in l for k in need)]
    if not matches: continue
    a("--- "+os.path.relpath(p,base)+" ---")
    used=set()
    for i in matches[:6]:
        for j in range(max(0,i-2),min(len(lines),i+4)):
            if j not in used:
                a(f"{j+1}: {lines[j][:300]}"); used.add(j)
    count+=1
    if count>=8: break
if not count: a("未找到相关文本日志或正文片段。")
a()
a("===== 4. 诊断结论边界 =====")
a("若本目录内没有目标文件，只能说明本次扫描范围未找到；不能推断文件已丢失。此时需按历史测试运行目录或报告中的实际路径继续定位。")
full="\n".join(out)+"\n"
open(report,"w",encoding="utf-8").write(full)
share=full if len(full)<=11500 else full[:11500]+"\n[分享摘要达到长度上限；完整报告保留在本机]\n"
open(report+".share","w",encoding="utf-8").write(share)
print("完整报告:",report)
print("完整字符数:",len(full),"分享字符数:",len(share))
PY
cat "$REPORT.share" | termux-share -a send -c text/plain
