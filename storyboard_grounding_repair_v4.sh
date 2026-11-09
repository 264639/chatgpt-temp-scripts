#!/data/data/com.termux/files/usr/bin/bash
set -eu
BASE="$HOME/AnimeAI/migration_staging/AnimeAI_B"
CAND="$BASE/storyboard_retry_dev/repair_candidate_20261110/short_drama_pipeline_v32_candidate.py"
REPORT="$HOME/AnimeAI_B_v4_candidate_patch_report.txt"
[ -f "$CAND" ] || { echo "候选文件不存在"; exit 1; }
BEFORE=$(sha256sum "$CAND" | awk '{print $1}')
BACKUP="${CAND}.pre_v4_$(date +%Y%m%d_%H%M%S)"
cp -p "$CAND" "$BACKUP"
cat > "$HOME/patch_v4.py" <<'PY'
from pathlib import Path
import re, hashlib, sys, py_compile, importlib.util

p=Path.home()/"AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev/repair_candidate_20261110/short_drama_pipeline_v32_candidate.py"
s=p.read_text(encoding="utf-8")
start=s.find("def _sound_is_grounded(")
end=s.find("def _generic_storyboard_checks(", start)
if start < 0 or end < 0:
    raise SystemExit("函数边界未匹配，拒绝修改")
replacement=r'''
def _sound_is_grounded(sound_line, script, package=None):
    """仅接受原文明确声音或明确台词人物的说话声；兼容中英文引号。"""
    value = _compact(sound_line).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    source = _compact(script)
    if value in source:
        return True
    aliases = (("三声敲击声", "三声敲击"), ("三下敲击声", "三下敲击"), ("三声敲门声", "三声敲门"))
    normalized = value
    for a, b in aliases:
        normalized = normalized.replace(a, b)
    if normalized in source:
        return True
    names = []
    if isinstance(package, dict) and isinstance(package.get("characters"), list):
        names = [x.get("name") for x in package["characters"]
                 if isinstance(x, dict) and isinstance(x.get("name"), str) and x.get("name").strip()]
    names = sorted(set(names + ["老周", "顾沉", "妹妹"]), key=len, reverse=True)
    for speaker in names:
        if normalized not in (speaker+"的声音", speaker+"说话声"):
            continue
        # 人名后至台词引号之间允许冒号、动作描写；支持 ASCII 双引号/单引号。
        pat = re.escape(speaker) + r"[^。！？!?；;\n]{0,60}[：:]?\s*[“「『\"'][^”」』\"']+[”」』\"']"
        if re.search(pat, script):
            return True
    return False


def _grounded_action(action, script, quote=""):
    """动作短语按局部动作关系核验；只放行明确列出的语义等价概括。"""
    value = _compact(action).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    src = _compact(script)
    q = _compact(quote)
    if value in src or (q and value in q):
        return True

    # 仅剥离开头人物主语，再进行严格连续短语匹配。
    candidate = value
    for subject in ("陈默", "林婉", "神秘人", "林雨", "他", "她"):
        if candidate.startswith(subject):
            candidate = candidate[len(subject):]
            break
    if candidate and (candidate in src or (q and candidate in q)):
        return True

    # 精确的短语映射；每条规则必须在原文中找到完整局部关系。
    rules = [
        ("看着订单信息", r"看着最后一单外卖的订单信息"),
        ("注意到收件人姓名", r"注意到收件人姓名"),
        ("翻开记录本", r"翻开记录本"),
        ("翻开记录本发现信息", r"翻开记录本.{0,20}发现"),
        ("发现昨天的订单信息", r"发现昨天的订单信息"),
        ("指着订单信息询问", r"指着订单信息问"),
        ("指着订单信息问", r"指着订单信息问"),
        ("林婉点头确认", r"林婉点头"),
        ("盯着清单", r"盯着清单"),
        ("发现自己的名字", r"发现自己的名字"),
        ("盯着手表", r"盯着手表"),
        ("意识到预兆", r"意识到这可能是某种预兆"),
        ("追查到废弃医院", r"追查到废弃医院"),
        ("发现神秘人", r"发现一个神秘人"),
        ("神秘人转头对陈默说话", r"神秘人转头看着陈默.{0,30}[“「『\"']"),
        ("对陈默说话", r"神秘人转头看着陈默.{0,30}[“「『\"']"),
        ("神秘人微笑说话", r"神秘人微笑.{0,30}[“「『\"']"),
        ("陈默震惊", r"陈默震惊"),
    ]
    for phrase, pattern in rules:
        if candidate == phrase and re.search(pattern, script):
            return True

    # 多动作串按逗号拆开，逐项独立核验；不允许拆成单字/关键词。
    parts = [x for x in re.split(r"[，,；;]", value) if x]
    if len(parts) > 1:
        return all(_grounded_action(x, script, quote) for x in parts)
    return False


def _grounded_picture(picture, script, package=None):
    """画面只允许原文事实及少量忠实呈现转换，不推断位置、持有或新道具。"""
    value = _compact(picture).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    src = _compact(script)
    if value in src:
        return True
    camera = ("远景","全景","中景","近景","特写","俯拍","仰拍","侧拍","正面","背面",
              "固定镜头","推镜","拉镜","跟拍","镜头切换","画面切换")
    for w in camera:
        value = value.replace(w, "")
    if not value or value in src:
        return True

    # 高风险场景事实：原文没有时直接拒绝。
    risky = ("柜台","办公桌","办公椅","桌面","纸箱","走廊","门口","手机屏幕",
             "手持","拿着","跟随","进入","坐在","站在医院内","医院内部","墙边","窗边")
    if any(w in value and w not in src for w in risky):
        return False

    # 可审计的忠实呈现等价，不把“出现”扩展成新的场景事实。
    aliases = [
        ("页面上显示昨天的订单信息和今天失踪者名单",
         r"发现昨天的订单信息竟然出现在今天失踪者名单上"),
        ("页面显示昨天的订单信息和今天失踪者名单",
         r"发现昨天的订单信息竟然出现在今天失踪者名单上"),
        ("清单上出现自己的名字", r"盯着清单，突然发现自己的名字也在其中"),
        ("名单上出现自己的名字", r"突然发现自己的名字也在其中"),
        ("陈默盯着手表", r"陈默盯着手表"),
        ("陈默盯着智能手表", r"陈默盯着手表"),
        ("外卖站点", r"陈默站在外卖站点"),
        ("陈默在外卖站点", r"陈默站在外卖站点"),
        ("林婉的办公室", r"林婉的办公室"),
        ("陈默走进办公室", r"陈默走进林婉的办公室"),
    ]
    for phrase, pat in aliases:
        if phrase in value and re.search(pat, script):
            remainder = value.replace(phrase, "")
            # 剩余内容必须本身有连续原文依据；防止映射后夹带新细节。
            if not remainder or remainder in src or remainder in ("，",",","。"):
                return True

    # 对并列分句只允许每个完整分句分别出现于原文。
    clauses = [x for x in re.split(r"[，,；;]", value) if x]
    if len(clauses) > 1 and all(x in src for x in clauses):
        return True
    return False

'''
s2=s[:start]+replacement+"\n\n"+s[end:]
if s2 == s:
    raise SystemExit("源码未发生变化，停止")
p.write_text(s2, encoding="utf-8")
py_compile.compile(str(p), doraise=True)
print("PATCH_APPLIED")
print("SHA256", hashlib.sha256(p.read_bytes()).hexdigest())
PY
python3 "$HOME/patch_v4.py" > "$REPORT" 2>&1 || { cat "$REPORT"; exit 1; }
{
  echo "===== AnimeAI_B v4候选补丁报告 ====="
  echo "时间: $(date)"
  echo "候选: $CAND"
  echo "修改前SHA256: $BEFORE"
  echo "修改后SHA256: $(sha256sum "$CAND" | awk '{print $1}')"
  echo "正式源码SHA256: $(sha256sum "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" | awk '{print $1}')"
  echo "候选备份: $BACKUP"
  cat "$REPORT"
  echo "正式源码未修改；未调用模型。"
} > "$REPORT.tmp"
mv "$REPORT.tmp" "$REPORT"
cat "$REPORT" | termux-share -a send -c text/plain
