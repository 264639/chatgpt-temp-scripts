#!/data/data/com.termux/files/usr/bin/bash
set -eu

BASE="$HOME/AnimeAI/migration_staging/AnimeAI_B"
WORK="$BASE/storyboard_retry_dev/repair_candidate_20261110"
CAND="$WORK/short_drama_pipeline_v32_candidate.py"
REPORT="$HOME/AnimeAI_B_storyboard_patch_report.txt"
EXPECTED="f1655c78123c8bc3f97338d66e7297a529397e75b94991020604bd7290831ddf"

echo "===== AnimeAI_B 分镜验收修复候选补丁 ====="
echo "时间：$(date)"
echo "候选文件：$CAND"

[ -f "$CAND" ] || { echo "ERROR：候选源码不存在"; exit 2; }
[ -f "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" ] || { echo "ERROR：正式源码不存在"; exit 2; }

ACTUAL="$(sha256sum "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "ERROR：正式源码身份变化，停止"; exit 3; }

CAND_BEFORE="$(sha256sum "$CAND" | awk '{print $1}')"
mkdir -p "$WORK/pre_patch_backup"
cp -p "$CAND" "$WORK/pre_patch_backup/short_drama_pipeline_v32_candidate_before.py"

python - <<'PY'
from pathlib import Path
p = Path.home() / "AnimeAI/migration_staging/AnimeAI_B/storyboard_retry_dev/repair_candidate_20261110/short_drama_pipeline_v32_candidate.py"
s = p.read_text(encoding="utf-8")

start = s.index("def _sound_is_grounded(")
end = s.index("\n\ndef _generic_storyboard_checks(", start)
new_sound = r'''def _sound_is_grounded(sound_line, script, package=None):
    """声音只允许原文明确声音或原文台词对应的说话声。"""
    value = _compact(sound_line).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    source = _compact(script)
    aliases = (
        ("三声敲击声", "三声敲击"),
        ("三下敲击声", "三下敲击"),
        ("三声敲门声", "三声敲门"),
    )
    normalized = value
    for alias, canonical in aliases:
        normalized = normalized.replace(alias, canonical)
    if normalized in source:
        return True

    names = []
    if isinstance(package, dict) and isinstance(package.get("characters"), list):
        names = [
            x.get("name") for x in package["characters"]
            if isinstance(x, dict) and isinstance(x.get("name"), str) and x.get("name").strip()
        ]
    # 兼容既有专用剧情包
    names.extend(["老周", "顾沉", "妹妹"])
    names = sorted(set(names), key=len, reverse=True)

    for speaker in names:
        if normalized in (speaker + "的声音", speaker + "说话声"):
            # 必须能在正式剧本中找到该人物明确台词，不能把点头、震惊等动作当声音。
            pattern = re.escape(speaker) + r"[^。！？!?；;\n]{0,50}[“「『][^”」』]+[”」』]"
            if re.search(pattern, script):
                return True
    return False


def _grounded_action(action, script, quote=""):
    """按动作短语核验；仅允许有原文语义锚点的有限表达归一化。"""
    value = _compact(action).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    source = _compact(script)
    local = _compact(quote)
    evidence = source + "。" + local
    if value in source or (local and value in local):
        return True

    # 去掉仅用于补全指代的主语，不放宽动作与对象的关系。
    subjects = ("陈默", "林婉", "神秘人", "林雨", "他", "她")
    candidate = value
    for name in subjects:
        if candidate.startswith(name):
            candidate = candidate[len(name):]
            break
    if candidate and (candidate in source or candidate in local):
        return True

    # 少量可审计的同义表达；每条都要求原文中出现对应动作和对象。
    rules = (
        (r"^(?:注意到)?收件人姓名$", r"注意到收件人姓名"),
        (r"^(?:发现)?信息$", r"发现.{0,16}(?:信息|订单信息|名单)"),
        (r"^翻开记录本发现信息$", r"翻开记录本.{0,20}发现"),
        (r"^指着订单信息询问$", r"指着订单信息问"),
        (r"^指着订单信息问$", r"指着订单信息问"),
        (r"^林婉点头确认$", r"林婉点头"),
        (r"^神秘人转头对陈默说话$", r"神秘人转头看着陈默.{0,30}[“「『]"),
        (r"^对陈默说话$", r"神秘人转头看着陈默.{0,30}[“「『]"),
        (r"^神秘人微笑说话$", r"神秘人微笑.{0,30}[“「『]"),
        (r"^发现自己的名字$", r"发现自己的名字"),
        (r"^盯着清单发现自己的名字$", r"盯着清单.{0,16}发现自己的名字"),
        (r"^追查到废弃医院$", r"追查到废弃医院"),
        (r"^发现神秘人$", r"发现一个神秘人"),
    )
    for action_pattern, source_pattern in rules:
        if re.fullmatch(action_pattern, candidate):
            if re.search(source_pattern, evidence):
                return True

    # 多动作短语必须逐项有依据，不能因一句中某个词命中而整体放行。
    parts = [x for x in re.split(r"[，,；;和并]", value) if x]
    if len(parts) > 1:
        return all(_grounded_action(x, script, quote) for x in parts)
    return False


def _grounded_picture(picture, script, package=None):
    """画面核验优先拒绝未经原文支持的位置、持有关系和新增实体。"""
    value = _compact(picture).rstrip("。！？!?；;，,")
    if value in ("", "未指定", "无"):
        return True
    source = _compact(script)
    if value in source:
        return True

    camera_words = (
        "远景", "全景", "中景", "近景", "特写", "俯拍", "仰拍", "侧拍",
        "正面", "背面", "固定镜头", "推镜", "拉镜", "跟拍", "镜头切换", "画面切换"
    )
    for word in camera_words:
        value = value.replace(word, "")
    if not value:
        return True
    if value in source:
        return True

    # 这些词涉及具体位置、持有关系或未在原文说明的场景实体。
    # 若未来正式剧本明确写出该事实，则不拦截。
    risky_terms = (
        "柜台", "办公桌", "办公椅", "桌面", "纸箱", "走廊", "门口",
        "手机", "屏幕", "手持", "拿着", "跟随", "进入", "坐在",
        "站在桌前", "站在医院内", "医院内部", "墙边", "窗边"
    )
    for term in risky_terms:
        if term in value and term not in source:
            return False

    # 允许“页面显示/清单出现”等纯呈现表达，但其承载的事实必须来自原文。
    visual_aliases = (
        ("页面上显示", "出现在"),
        ("清单上出现", "出现在"),
        ("名单上出现", "出现在"),
        ("页面显示", "出现在"),
        ("显示", "出现在"),
    )
    candidate = value
    for alias, canonical in visual_aliases:
        candidate = candidate.replace(alias, canonical)
    if candidate in source:
        return True

    # 允许原文明确人物、地点和动作的并列式镜头描述；
    # 每个逗号分句都必须有原文短语锚点，不能只靠共享实体词通过。
    clauses = [x for x in re.split(r"[，,；;]", candidate) if x]
    if len(clauses) > 1:
        return all(clause in source for clause in clauses)

    # 对“某人+动作+具体地点/对象”不做猜测式放行。
    return False
'''
s = s[:start] + new_sound + s[end:]

start = s.index("def _generic_storyboard_checks(")
end = s.index("\n\ndef storyboard_checks(", start)
new_generic = r'''def _generic_storyboard_checks(text, script, package):
    out = []
    def add(name, ok, detail):
        out.append({"check": name, "status": "PASS" if ok else "FAIL", "detail": detail})

    blocks = [x.strip() for x in re.split(r"(?m)(?=^镜头(?:编号)?[：:\s]*\d+\s*$)", text.strip()) if x.strip()]
    blocks = [b for b in blocks if re.search(r"(?m)^镜头(?:编号)?[：:\s]*\d+\s*$", b)]
    add("通用分镜镜头数量", len(blocks) >= 3, f"识别到{len(blocks)}镜，至少要求3镜")

    events = package.get("event_order") if isinstance(package, dict) else None
    event_list_ok = isinstance(events, list) and bool(events) and all(isinstance(x, str) and x.strip() for x in events)
    add("分镜事件依据", event_list_ok, "使用资料包event_order" if event_list_ok else "缺少有效event_order，无法核验事件覆盖")
    if not blocks:
        add("分镜字段完整", False, "没有识别到有效镜头块")
        add("分镜事件覆盖与顺序", False, "没有可核验的镜头事件")
        add("分镜原文出处与顺序", False, "没有可核验的原文摘录")
        add("分镜动作/画面/声音依据", False, "没有可核验的镜头内容")
        return out

    labels = ("对应核心事件", "对应原文事件", "景别", "画面", "动作", "声音")
    field_rows = []
    for block in blocks:
        row = {}
        for label in labels:
            m = re.search(rf"(?m)^{re.escape(label)}[：:]\s*(.+)$", block)
            row[label] = m.group(1).strip() if m else ""
        field_rows.append(row)
    fields_ok = all(all(row.get(k) for k in labels) for row in field_rows)
    add("分镜字段完整", fields_ok, "每镜均包含核心事件、原文事件、景别、画面、动作、声音" if fields_ok else "至少一个镜头缺少必需字段")

    event_labels = [row.get("对应核心事件", "") for row in field_rows]
    allowed = set(events) if event_list_ok else set()
    event_values_ok = event_list_ok and all(x in allowed for x in event_labels)
    collapsed = []
    for value in event_labels:
        if value and (not collapsed or collapsed[-1] != value):
            collapsed.append(value)
    order_ok = event_values_ok and collapsed == events
    add("分镜事件覆盖与顺序", order_ok, "全部核心事件按event_order顺序覆盖，可为同一事件安排多个连续镜头" if order_ok else f"镜头事件序列{collapsed}与资料包顺序{events if event_list_ok else '无效'}不一致")

    source = _compact(script)
    quotes = [row.get("对应原文事件", "") for row in field_rows]
    quote_positions = []
    quote_ok = bool(quotes)
    for quote in quotes:
        q = _compact(quote)
        pos = source.find(q) if q else -1
        if pos < 0:
            quote_ok = False
        quote_positions.append(pos)
    quote_order_ok = quote_ok and quote_positions == sorted(quote_positions)
    add("分镜原文出处与顺序", quote_order_ok, "每镜均引用剧本连续原文且顺序不倒置" if quote_order_ok else "原文事件不是连续原文、无法定位或顺序倒置")

    content_ok = True
    problems = []
    for i, row in enumerate(field_rows, 1):
        quote = row.get("对应原文事件", "")
        action = row.get("动作", "")
        picture = row.get("画面", "")
        sound = row.get("声音", "")
        if not _grounded_action(action, script, quote):
            content_ok = False
            problems.append(f"第{i}镜动作无充分原文依据：{action}")
        if not _grounded_picture(picture, script, package):
            content_ok = False
            problems.append(f"第{i}镜画面含未经原文支持的事实：{picture}")
        if not _sound_is_grounded(sound, script, package):
            content_ok = False
            problems.append(f"第{i}镜声音无原文依据：{sound}")
    add("分镜动作/画面/声音依据", content_ok,
        "动作短语、画面事实和声音均有原文依据" if content_ok else "；".join(problems))
    return out
'''
s = s[:start] + new_generic + s[end:]

# 更新通用 Prompt：把可执行边界写清楚，避免模型自行补景。
old = '''    return f"""你是严格的分镜导演。只能把正式剧本转成镜头，不得续写、改编或补充剧情。
正式剧本：
{package.get('script', '')}

本集核心事件顺序（必须完整覆盖，不能调换）：
{json.dumps(events, ensure_ascii=False)}

输出规则：
1. 至少3个镜头；镜头数量由剧情动作和信息变化决定，不得机械地一事件一镜。一个核心事件可以拆成多个连续镜头。
2. 每镜必须标明“对应核心事件”，其值必须逐字选自上面的event_order；允许连续多个镜头对应同一事件，但事件整体顺序必须一致。
3. 每镜必须有独立字段，且每个字段单独占一行：镜头编号、对应核心事件、对应原文事件、景别、画面、动作、声音。
4. “对应原文事件”必须直接摘录正式剧本中的连续原文，不得概括、改写、拼接不同位置；所有镜头按原文顺序排列。
5. 动作只能摘录正式剧本已有的动作；没有明确动作写“未指定”。
6. 画面只能描述正式剧本明确出现的事实。允许在景别字段使用远景/全景/中景/近景/特写等镜头语言，但不能新增人物姿态、表情、视线、道具状态、光线、环境或动作。
7. 声音只能摘录正式剧本明确写出的声音；没有明确声音写“未指定”。不得自行添加音乐、音效或环境声。
8. 不得新增人物、道具、台词、关系、事实或事件；只输出分镜正文，不要解释。

每镜格式示例（示例结构，不是剧情内容）：
镜头编号：1
对应核心事件：从event_order中选择一项
对应原文事件：从正式剧本摘录连续原文
景别：中景
画面：只写原文可支持的画面事实
动作：摘录原文动作或写未指定
声音：摘录原文声音或写未指定
"""'''
new = '''    return f"""你是严格的分镜导演。只能把正式剧本转成镜头，不得续写、改编或补充剧情。
正式剧本是唯一事实来源；资料包只用于理解人物、地点、道具和事件顺序，不能证明原文没有写出的具体位置、状态或动作。
正式剧本：
{package.get('script', '')}

本集核心事件顺序（必须完整覆盖，不能调换）：
{json.dumps(events, ensure_ascii=False)}

输出规则：
1. 至少3个镜头；镜头数量由剧情动作和信息变化决定，不得机械地一事件一镜。一个核心事件可以拆成多个连续镜头。
2. 每镜必须标明“对应核心事件”，其值必须逐字选自上面的event_order；允许连续多个镜头对应同一事件，但事件整体顺序必须一致。
3. 每镜必须有独立字段，且每个字段单独占一行：镜头编号、对应核心事件、对应原文事件、景别、画面、动作、声音。
4. “对应原文事件”必须直接摘录正式剧本中的连续原文，不得概括、改写、拼接不同位置；所有镜头按原文顺序排列。
5. 动作只写原文明确发生的动作。允许补全明确的人物姓名或代词指代，允许不改变对象和结果的简洁表达；不得把心理判断扩写成身体动作，不得增加原文没有的动作。
6. 画面只写原文能够直接支持的可见事实。景别只写在“景别”字段。不得推测柜台、桌面、办公椅、手机、屏幕、纸箱、走廊、门口、人物站坐位置、手持关系、光线、环境布置或道具状态。
7. “某物在资料包中出现”不代表它可以被放置到任意位置，也不代表可以推断其外观、摆放、持有或显示状态。原文只说“整理遗物”，不得改成“整理纸箱”。
8. 声音只允许原文明示的声音，或原文明确台词对应的该人物说话声。没有明确声音写“未指定”；点头声、震惊声、呼吸声、背景音乐等不得自行添加。
9. 不得新增人物、道具、台词、关系、事实或事件；只输出分镜正文，不要解释。

每镜格式示例（示例结构，不是剧情内容）：
镜头编号：1
对应核心事件：从event_order中选择一项
对应原文事件：从正式剧本摘录连续原文
景别：中景
画面：只写原文可支持的画面事实
动作：写有原文依据的动作；没有明确动作写未指定
声音：写原文明示声音；没有明确声音写未指定
"""'''
if old not in s:
    raise SystemExit("ERROR: 通用 storyboard_prompt 原文模板未精确匹配，拒绝部分修改")
s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
print("PATCH_APPLIED")
PY

python -m py_compile "$CAND"

echo
echo "===== 候选源码修改结果 ====="
echo "修改前SHA256：$CAND_BEFORE"
echo "修改后SHA256：$(sha256sum "$CAND" | awk '{print $1}')"
echo "正式源码SHA256：$(sha256sum "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" | awk '{print $1}')"
echo "候选语法检查：PASS"
echo "正式源码未修改。"
echo "候选修改前备份：$WORK/pre_patch_backup/short_drama_pipeline_v32_candidate_before.py"

{
  echo "===== AnimeAI_B 分镜验收修复候选补丁报告 ====="
  echo "时间：$(date)"
  echo "候选文件：$CAND"
  echo "修改前候选SHA256：$CAND_BEFORE"
  echo "修改后候选SHA256：$(sha256sum "$CAND" | awk '{print $1}')"
  echo "正式源码SHA256：$(sha256sum "$BASE/storyboard_retry_dev/short_drama_pipeline_v32.py" | awk '{print $1}')"
  echo "候选Python语法检查：PASS"
  echo "本次仅修改候选副本，未覆盖正式源码。"
  echo "尚未运行离线回归，尚未调用模型。"
} > "$REPORT"

echo
cat "$REPORT" | termux-share -a send -c text/plain
