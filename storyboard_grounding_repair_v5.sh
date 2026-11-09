#!/data/data/com.termux/files/usr/bin/bash
set -eu
BASE="$HOME/AnimeAI/migration_staging/AnimeAI_B"
CAND="$BASE/storyboard_retry_dev/repair_candidate_20261110/short_drama_pipeline_v32_candidate.py"
REPORT="$HOME/AnimeAI_B_v5_patch_report.txt"
[ -f "$CAND" ] || { echo "候选文件不存在：$CAND"; exit 1; }
BEFORE=$(sha256sum "$CAND" | awk '{print $1}')
BACKUP="${CAND}.pre_v5_$(date +%Y%m%d_%H%M%S)"
cp -p "$CAND" "$BACKUP"
cat > "$HOME/patch_v5.py" <<'PY'
from pathlib import Path
import re, hashlib, py_compile, ast

p=Path.home()/"AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev/repair_candidate_20261110/short_drama_pipeline_v32_candidate.py"
s=p.read_text(encoding="utf-8")
a=s.find("def _sound_is_grounded(")
b=s.find("def _generic_storyboard_checks(", a)
if a < 0 or b < 0:
    raise SystemExit("验收函数边界不匹配，未修改")
block=r'''
def _sound_is_grounded(sound_line, script, package=None):
    """声音必须有原文依据；台词说话声须能定位到该人物的引语。"""
    v = _compact(sound_line).strip("。！？!?；;，,")
    if v in ("", "无", "未指定"):
        return True
    src = _compact(script)
    if v in src:
        return True
    # 台词说话声：人物名 + 台词引号，兼容中英文引号。
    names = ["老周", "顾沉", "妹妹"]
    if isinstance(package, dict) and isinstance(package.get("characters"), list):
        names += [x.get("name", "") for x in package["characters"] if isinstance(x, dict)]
    names = sorted({n for n in names if isinstance(n, str) and n}, key=len, reverse=True)
    for name in names:
        if v not in (name+"说话声", name+"的声音"):
            continue
        pat = re.escape(name) + r"[^。！？!?；;\n]{0,80}?[：:]?\s*[“「『\"'][^”」』\"']+[”」』\"']"
        if re.search(pat, script):
            return True
    # 明确声音同义词，不允许把人物反应推断成声音。
    aliases = {"三声敲击声":"三声敲击", "敲门声":"敲门", "脚步声":"脚步"}
    nv = v
    for x,y in aliases.items():
        nv = nv.replace(x,y)
    return nv in src


def _grounded_action(action, script, quote=""):
    """以完整动作短语或明确同义表达核验，不进行全文散词拼接。"""
    v = _compact(action).strip("。！？!?；;，,")
    if v in ("", "无", "未指定"):
        return True
    src = _compact(script)
    q = _compact(quote)
    if v in src or (q and v in q):
        return True
    # 只去除开头的已知主语；动作谓语和宾语必须连续匹配。
    c = v
    for n in ("陈默","林婉","神秘人","林雨","他","她"):
        if c.startswith(n):
            c = c[len(n):]
            break
    if c and (c in src or (q and c in q)):
        return True
    # 有限的忠实概括映射。映射目标必须作为连续局部事实存在。
    mappings = {
      "翻开记录本发现信息": ("翻开记录本", "发现"),
      "指着订单信息询问": ("指着订单信息问",),
      "指着订单信息问": ("指着订单信息问",),
      "林婉点头确认": ("林婉点头",),
      "盯着清单": ("盯着清单",),
      "发现自己的名字": ("发现自己的名字",),
      "盯着手表": ("盯着手表",),
      "意识到预兆": ("意识到这可能是某种预兆",),
      "追查到废弃医院": ("追查到废弃医院",),
      "发现神秘人": ("发现一个神秘人",),
      "神秘人转头对陈默说话": ("神秘人转头看着陈默",),
      "转头对陈默说话": ("神秘人转头看着陈默",),
      "神秘人微笑说话": ("神秘人微笑",),
      "微笑说话": ("神秘人微笑",),
    }
    for phrase, needles in mappings.items():
        if c == phrase and all(x in src for x in needles):
            return True
    # 多动作分句逐条验证完整短语，禁止关键词跨句凑证据。
    parts = [x for x in re.split(r"[，,；;]", v) if x]
    if len(parts) > 1:
        return all(_grounded_action(x, script, quote) for x in parts)
    return False


def _grounded_picture(picture, script, package=None):
    """画面事实只允许原文连续证据或白名单等价表达。"""
    v = _compact(picture).strip("。！？!?；;，,")
    if v in ("", "无", "未指定"):
        return True
    src = _compact(script)
    # 去除纯镜头术语，不去除任何场景/道具/动作词。
    for x in ("远景","全景","中景","近景","特写","俯拍","仰拍","侧拍","正面","背面","固定镜头","跟拍"):
        v = v.replace(x,"")
    if not v or v in src:
        return True
    forbidden = ("柜台","办公桌","办公椅","纸箱","走廊","手机屏幕","手持","拿着","跟随进入","坐在","医院门口","医院内部")
    if any(x in v and x not in src for x in forbidden):
        return False
    # 画面描述映射：验证完整事件语境，而非拆词搜索。
    mappings = [
      (("页面上显示昨天的订单信息和今天失踪者名单","页面显示昨天的订单信息和今天失踪者名单"),
       ("发现昨天的订单信息竟然出现在今天失踪者名单上",)),
      (("清单上出现自己的名字","名单上出现自己的名字"),
       ("盯着清单","发现自己的名字也在其中")),
      (("陈默盯着手表","陈默盯着智能手表"), ("陈默盯着手表",)),
      (("陈默走进办公室","陈默进入林婉办公室"), ("陈默走进林婉的办公室",)),
      (("外卖站点","陈默在外卖站点"), ("陈默站在外卖站点",)),
    ]
    for variants, evidence in mappings:
        for phrase in variants:
            if phrase in v and all(x in src for x in evidence):
                remainder = v.replace(phrase,"")
                # 只接受标点/镜头残留；任何未解释文字均拒绝。
                if not remainder.strip("，,。；;：: "):
                    return True
    # 每个完整并列分句都必须在原文中连续出现；不允许跨句拼接。
    parts = [x for x in re.split(r"[，,；;]", v) if x]
    if len(parts) > 1 and all(x in src for x in parts):
        return True
    return False

'''
s2=s[:a]+block+"\n\n"+s[b:]
if s2 == s: raise SystemExit("无源码变化")
# 只写候选副本；先语法编译，再做辅助函数的独立正反例测试。
compile(s2, str(p), "exec")
p.write_text(s2, encoding="utf-8")
py_compile.compile(str(p), doraise=True)
# AST抽取三个函数，避免导入项目时触发模型/外部依赖。
tree=ast.parse(s2)
wanted={"_compact","_sound_is_grounded","_grounded_action","_grounded_picture"}
nodes=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name in wanted]
ns={"re":re}
exec(compile(ast.Module(body=nodes,type_ignores=[]),"<grounding-selftest>","exec"),ns)
assert ns["_grounded_action"]("陈默翻开记录本发现信息","陈默翻开记录本，发现昨天的订单信息")
assert ns["_grounded_action"]("陈默盯着手表","陈默盯着手表，突然意识到这可能是某种预兆")
assert ns["_grounded_action"]("神秘人转头对陈默说话",'神秘人转头看着陈默："你终于来了。"')
assert not ns["_grounded_action"]("陈默站在医院","陈默站在外卖站点。随后他追查到废弃医院")
assert ns["_grounded_picture"]("清单上出现自己的名字","陈默盯着清单，突然发现自己的名字也在其中")
assert not ns["_grounded_picture"]("陈默站在医院内","陈默站在外卖站点。随后他追查到废弃医院")
assert not ns["_grounded_picture"]("神秘人整理纸箱","神秘人正在整理遗物")
assert ns["_sound_is_grounded"]("陈默说话声",'陈默问："你是谁？为什么？"',{"characters":[{"name":"陈默"}]})
assert not ns["_sound_is_grounded"]("陈默震惊声","陈默震惊")
print("SELFTEST_PASS 9/9")
print("PATCH_APPLIED")
print("SHA256",hashlib.sha256(p.read_bytes()).hexdigest())
PY
python "$HOME/patch_v5.py" > "$REPORT" 2>&1
{
 echo "===== AnimeAI_B v5候选修复 ====="
 echo "修改前SHA256: $BEFORE"
 echo "修改后SHA256: $(sha256sum "$CAND" | awk '{print $1}')"
 echo "正式源码SHA256: $(sha256sum "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" | awk '{print $1}')"
 echo "候选备份: $BACKUP"
 cat "$REPORT"
 echo "范围：仅替换候选版动作/画面/声音依据函数；不修改正式源码、不调用模型。"
} > "$REPORT.tmp"
mv "$REPORT.tmp" "$REPORT"
cat "$REPORT" | termux-share -a send -c text/plain
