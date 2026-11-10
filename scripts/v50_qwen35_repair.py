#!/usr/bin/env python3
"""AnimeAI V50 Qwen3.5 ARM64 controlled repair; one-shot, backup-first."""
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, time, urllib.request
from pathlib import Path

REPO_RAW = "https://raw.githubusercontent.com/264639/chatgpt-temp-scripts/main/patches/AnimeAI_V50/PATCH_03/src/v50_model.py"
PATCH_SHA256 = "a67609bb60ce6e916e53ae15b327e76bc93b6168cfc321b645c2eda38ce3b373"
BASE_CHAT_SHA = "31d51de7c4892070908bb3881fa1d48745a53df1416f31dcfa93077c21acba85"
PATCH2_CHAT_SHA = "adcafbba264d44156ba8d1730f15a4c130af9c59fdc59f1c93c045072aec6508"
BASE_MODEL_SHA = "94858144fa49343fef91e970cb1a73beb480d6b4971ad26927c5d80f9242ee3c"
PATCH2_MODEL_SHA = "a637ade25da97a29127f752529137c7b3e54ac98e970ebcd9deaecad5316fd31"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def fingerprint(path: Path) -> dict:
    st = path.stat()
    return {"size": st.st_size, "mtime_ns": st.st_mtime_ns}


def locate_root() -> Path:
    candidates = [Path("/root/AnimeAI_V50"), Path.home() / "AnimeAI_V50", Path.cwd()]
    for p in candidates:
        if (p / "src/v50_model.py").is_file() and (p / "models/Qwen3.5-4B-Q4_K_M.gguf").is_file():
            return p.resolve()
    raise RuntimeError("找不到 AnimeAI_V50 项目根目录或 Qwen3.5-4B 模型文件")


def run_probe(cmd: list[str], timeout: int = 600) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True,
                           timeout=timeout, check=False)
        return p.returncode, p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = e.stderr.decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        return 124, out, err + f"\nPROBE_TIMEOUT after {timeout}s"


def append_report(s: str) -> None:
    with REPORT.open("a", encoding="utf-8") as f:
        f.write(s + ("\n" if not s.endswith("\n") else ""))


def probe_command(engine: Path, model: Path, ctx: int, batch: int, ubatch: int, threads: int, no_repack: bool) -> list[str]:
    prompt = "<|im_start|>user\n你好，请只回复成功。<|im_end|>\n<|im_start|>assistant\n"
    cmd = [str(engine), "-m", str(model), "-p", prompt, "-n", "4",
           "-c", str(ctx), "-t", str(threads), "-b", str(batch), "-ub", str(ubatch),
           "--flash-attn", "off", "--no-warmup", "--no-display-prompt", "-lv", "4"]
    if no_repack:
        cmd.append("--no-repack")
    return cmd


def patch_chat(chat_path: Path) -> str:
    current_sha = sha(chat_path)
    if current_sha == PATCH2_CHAT_SHA:
        return "CHAT_PATCH02_ALREADY_PRESENT"
    if current_sha != BASE_CHAT_SHA:
        raise RuntimeError(f"v50_chat.py 内容与已知基线不一致，拒绝覆盖：{current_sha}")
    text = chat_path.read_text(encoding="utf-8")
    text = text.replace(
        "<small>当前版本已支持会话与消息持久化；AI 推理后端尚未连接，不会生成虚假回复。</small>",
        "<small>消息会先保存到本地，再调用真实模型；模型失败时保留消息并显示错误，不伪造回复。</small>")
    old_send = '''  const d=await api('/api/chat',{method:'POST',body:JSON.stringify({session_id:currentId,message:text})});
  $('input').value='';
  renderMessages(d.session.messages);
  $('status').textContent='消息已保存 · 等待模型接入';
  await refreshSessions();'''
    new_send = '''  const saved=await api('/api/chat',{method:'POST',body:JSON.stringify({session_id:currentId,message:text})});
  $('input').value='';
  renderMessages(saved.session.messages);
  $('status').textContent='消息已保存 · 正在请求本地模型…';
  await refreshSessions();
  try{
   const generated=await api('/api/model/generate',{method:'POST',body:JSON.stringify({session_id:currentId,max_tokens:256})});
   renderMessages(generated.session.messages);
   $('status').textContent='本地模型已完成回复';
   await refreshSessions();
  }catch(modelError){
   $('status').textContent='消息已保存 · 模型暂不可用';
   const notice=document.createElement('div');
   notice.className='notice';
   notice.textContent='消息已经保存，但本次没有生成 AI 回复：'+modelError.message;
   $('messages').appendChild(notice);
   $('messages').scrollTop=$('messages').scrollHeight;
  }'''
    if old_send not in text:
        raise RuntimeError("聊天前端发送函数结构与预期不符，停止修改")
    text = text.replace(old_send, new_send)
    old_health = '''            return self.send_json(200, {
                "project": "AnimeAI V50 Chat",
                "chat_storage": str(DATA_FILE),
                "model_connected": False,
                "model_note": "推理后端尚未接通"
            })'''
    new_health = '''            model_state = model_adapter.status()
            return self.send_json(200, {
                "project": "AnimeAI V50 Chat",
                "chat_storage": str(DATA_FILE),
                "model_connected": bool(model_state.get("inference_verified")),
                "model_note": model_state.get("note", "模型尚未完成真实推理验收"),
                "model": model_state
            })'''
    if old_health not in text:
        raise RuntimeError("健康接口结构与预期不符，停止修改")
    text = text.replace(old_health, new_health)
    if "api('/api/model/generate'" not in text:
        raise RuntimeError("聊天生成接口静态验收失败")
    chat_path.write_text(text, encoding="utf-8")
    return "CHAT_PATCH02_APPLIED"


ROOT = locate_root()
MODEL = ROOT / "models/Qwen3.5-4B-Q4_K_M.gguf"
MODEL_ADAPTER = ROOT / "src/v50_model.py"
CHAT = ROOT / "src/v50_chat.py"
ENGINE = ROOT / "engine/llama.cpp/build-v50-generic-20261110_053339/bin/llama-cli"
if not ENGINE.is_file():
    candidates = [ROOT / "engine/llama.cpp/build-portable/bin/llama-cli", ROOT / "engine/llama.cpp/build/bin/llama-cli"]
    ENGINE = next((p for p in candidates if p.is_file()), None)
if ENGINE is None:
    raise RuntimeError("找不到可用 llama-cli")

REPORT_DIR = ROOT / "reports"
REPORT_DIR.mkdir(parents=True, exist_ok=True)
STAMP = time.strftime("%Y%m%d_%H%M%S")
REPORT = REPORT_DIR / f"V50_PATCH03_QWEN35_REPAIR_{STAMP}.txt"
REPORT.write_text("===== AnimeAI V50 Qwen3.5 受控修复 =====\n", encoding="utf-8")
append_report(f"时间：{time.strftime('%Y-%m-%d %H:%M:%S')}")
append_report(f"项目：{ROOT}")
append_report(f"引擎：{ENGINE}")
append_report(f"模型：{MODEL}")
append_report(f"模型SHA256：{sha(MODEL)}")
append_report("保护：不删除 data/model_fault.json；不修改模型文件；不触碰 AnimeAI_A/B")

help_run = subprocess.run([str(ENGINE), "--help"], cwd=str(ROOT), capture_output=True, text=True, timeout=30)
help_text = (help_run.stdout or "") + (help_run.stderr or "")
if "--flash-attn" not in help_text or "--ubatch-size" not in help_text:
    raise RuntimeError("当前 llama-cli 缺少 flash-attn/ubatch 参数，拒绝运行不兼容探针")
no_repack = ("--no-repack" in help_text) or ("-nr" in help_text)
append_report(f"CLI参数：flash-attn=支持；ubatch=支持；no-repack={'支持' if no_repack else '不支持'}")

probes = [(4096, 32, 8, 2, "TARGET_LOW_BATCH"), (512, 8, 2, 2, "SAFE_SMALL_CONTEXT")]
selected = None
for ctx, batch, ubatch, threads, label in probes:
    cmd = probe_command(ENGINE, MODEL, ctx, batch, ubatch, threads, no_repack)
    append_report(f"\n--- {label} ---")
    append_report("命令参数：" + " ".join(cmd[1:]))
    code, out, err = run_probe(cmd)
    append_report(f"退出码：{code}")
    append_report("标准输出末尾：\n" + out[-5000:])
    append_report("标准错误末尾：\n" + err[-8000:])
    if code == 0 and out.strip():
        selected = (ctx, batch, ubatch, threads, label, out.strip())
        break

if selected is None:
    append_report("\n结果：两个保守参数探针均未通过；没有修改任何源码、没有清除熔断记录。")
    if shutil.which("gdb"):
        ctx, batch, ubatch, threads, label = probes[-1]
        cmd = probe_command(ENGINE, MODEL, ctx, batch, ubatch, threads, no_repack)
        gdb_cmd = [shutil.which("gdb"), "--batch", "-ex", "set pagination off", "-ex", "run", "-ex", "thread apply all bt full", "--args", *cmd]
        code, out, err = run_probe(gdb_cmd, timeout=600)
        append_report("\n--- GDB回溯 ---\n" + (out + "\n" + err)[-12000:])
    else:
        append_report("GDB未安装，未伪造调用栈；当前报告保留两个参数组合的原始错误输出。")
    append_report("===== 修复未应用 =====")
    print(f"探针未通过；源码未修改。报告：{REPORT}")
    sys.exit(2)

ctx, batch, ubatch, threads, label, reply = selected
append_report(f"\n真实推理探针：PASS ({label})")
append_report(f"采用参数：ctx={ctx}, batch={batch}, ubatch={ubatch}, threads={threads}, flash-attn=off, no-repack={no_repack}")

backup = ROOT / "backups" / f"V50_PATCH_03_{STAMP}"
(backup / "src").mkdir(parents=True, exist_ok=True)
shutil.copy2(MODEL_ADAPTER, backup / "src/v50_model.py")
shutil.copy2(CHAT, backup / "src/v50_chat.py")
append_report(f"源码备份：{backup}")

try:
    current_model_sha = sha(MODEL_ADAPTER)
    current_model_text = MODEL_ADAPTER.read_text(encoding="utf-8")
    recognized_patch03 = ("def _probe_verified(" in current_model_text
                          and "DEFAULT_BATCH_SIZE" in current_model_text
                          and "fault_bypassed_by_verified_probe" in current_model_text)
    if current_model_sha not in (BASE_MODEL_SHA, PATCH2_MODEL_SHA, PATCH_SHA256) and not recognized_patch03:
        raise RuntimeError(f"v50_model.py 内容与已知基线/补丁不一致，拒绝覆盖：{current_model_sha}")
    with urllib.request.urlopen(REPO_RAW, timeout=30) as response:
        patch_bytes = response.read()
    actual_patch_sha = hashlib.sha256(patch_bytes).hexdigest()
    if actual_patch_sha != PATCH_SHA256:
        raise RuntimeError(f"GitHub补丁SHA256不匹配：{actual_patch_sha}")
    patch_tmp = ROOT / "backups" / f"V50_PATCH_03_model_download_{STAMP}.py"
    patch_tmp.write_bytes(patch_bytes)
    shutil.copy2(patch_tmp, MODEL_ADAPTER)

    chat_result = patch_chat(CHAT)
    cp = subprocess.run([sys.executable, "-m", "py_compile", str(MODEL_ADAPTER), str(CHAT)],
                        cwd=str(ROOT), capture_output=True, text=True)
    if cp.returncode != 0:
        raise RuntimeError("Python语法验收失败：" + (cp.stderr or cp.stdout)[-4000:])

    marker = {
        "engine": str(ENGINE), "model": str(MODEL),
        "engine_fingerprint": fingerprint(ENGINE),
        "model_fingerprint": fingerprint(MODEL),
        "probe_ok": True, "probe_label": label,
        "probe_args": {"ctx": ctx, "batch": batch, "ubatch": ubatch, "threads": threads,
                       "flash_attn": "off", "no_repack": no_repack},
        "verified_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "reply_chars": len(reply)
    }
    marker_path = ROOT / "data/model_inference_verified.json"
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    marker_tmp = marker_path.with_suffix(".json.tmp")
    marker_tmp.write_text(json.dumps(marker, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(marker_tmp, marker_path)

    model_text = MODEL_ADAPTER.read_text(encoding="utf-8")
    model_text = model_text.replace("DEFAULT_CONTEXT = 4096", f"DEFAULT_CONTEXT = {ctx}")
    model_text = model_text.replace("DEFAULT_THREADS = 2", f"DEFAULT_THREADS = {threads}")
    model_text = model_text.replace("DEFAULT_BATCH_SIZE = 32", f"DEFAULT_BATCH_SIZE = {batch}")
    model_text = model_text.replace("DEFAULT_UBATCH_SIZE = 8", f"DEFAULT_UBATCH_SIZE = {ubatch}")
    MODEL_ADAPTER.write_text(model_text, encoding="utf-8")
    cp = subprocess.run([sys.executable, "-m", "py_compile", str(MODEL_ADAPTER), str(CHAT)],
                        cwd=str(ROOT), capture_output=True, text=True)
    if cp.returncode != 0:
        raise RuntimeError("参数写入后的语法验收失败：" + (cp.stderr or cp.stdout)[-4000:])

    check = subprocess.run([sys.executable, str(MODEL_ADAPTER)], cwd=str(ROOT), capture_output=True, text=True)
    if check.returncode != 0:
        raise RuntimeError("适配器状态检查失败：" + (check.stderr or check.stdout)[-4000:])
    append_report(f"聊天界面补丁：{chat_result}")
    append_report("Python语法验收：PASS")
    append_report("模型适配器状态：\n" + (check.stdout or "")[-4000:])
    append_report("历史故障记录：保留，未删除；仅由匹配当前模型/引擎的真实探针标记解除阻断。")
    append_report("===== PATCH_03_APPLIED =====")
    print(f"PATCH_03_APPLIED；真实推理探针通过（{label}）。报告：{REPORT}")
except Exception as exc:
    shutil.copy2(backup / "src/v50_model.py", MODEL_ADAPTER)
    shutil.copy2(backup / "src/v50_chat.py", CHAT)
    try:
        (ROOT / "data/model_inference_verified.json").unlink(missing_ok=True)
    except OSError:
        pass
    append_report(f"补丁应用失败，已回滚源码：{type(exc).__name__}: {exc}")
    append_report("原始 data/model_fault.json 未修改。")
    print(f"补丁应用失败，已自动回滚。报告：{REPORT}")
    sys.exit(3)
