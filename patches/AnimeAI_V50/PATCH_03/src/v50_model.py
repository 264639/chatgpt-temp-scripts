#!/usr/bin/env python3
"""AnimeAI V50 模型适配器：带持久化段错误熔断保护。"""

import json
import subprocess
import time
import sys
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = ROOT / "models" / "Qwen3.5-4B-Q4_K_M.gguf"
FAULT_PATH = ROOT / "data" / "model_fault.json"
VERIFIED_PATH = ROOT / "data" / "model_inference_verified.json"
LOG_PATH = ROOT / "logs" / "model_inference.log"

# Prefer the latest V50 generic build. Keep older builds as fallbacks.
ENGINE_CANDIDATES = [
    ROOT / "engine/llama.cpp/build-v50-generic-20261110_053339/bin/llama-cli",
    ROOT / "engine/llama.cpp/build-portable/bin/llama-cli",
    ROOT / "engine/llama.cpp/build/bin/llama-cli",
]

# Conservative ARM64 defaults: avoid the large auto-reserved CPU graph and FA path
# that previously crashed on the K70 Pro during context graph reservation.
DEFAULT_CONTEXT = 4096
DEFAULT_THREADS = 2
DEFAULT_BATCH_SIZE = 32
DEFAULT_UBATCH_SIZE = 8
DEFAULT_TOKENS = 256
DEFAULT_TIMEOUT = 240


def _write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )
    os.replace(temp, path)


def _read_fault():
    if not FAULT_PATH.is_file():
        return None
    try:
        return json.loads(FAULT_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {
            "faulted": True,
            "error": "故障记录文件损坏，为安全起见禁止推理"
        }


def _file_fingerprint(path):
    try:
        st = Path(path).stat()
        return {"size": st.st_size, "mtime_ns": st.st_mtime_ns}
    except OSError:
        return None


def _probe_verified(engine=None):
    engine = engine or select_engine()
    if not engine or not MODEL_PATH.is_file():
        return False
    try:
        verified = json.loads(VERIFIED_PATH.read_text(encoding="utf-8"))
        return bool(
            verified.get("engine") == str(engine)
            and verified.get("model") == str(MODEL_PATH)
            and verified.get("engine_fingerprint") == _file_fingerprint(engine)
            and verified.get("model_fingerprint") == _file_fingerprint(MODEL_PATH)
            and verified.get("probe_ok") is True
        )
    except Exception:
        return False


def record_fault(error, returncode=None, stderr=""):
    # A fresh runtime failure invalidates any earlier successful probe.
    try:
        VERIFIED_PATH.unlink(missing_ok=True)
    except OSError:
        pass
    fault = {
        "faulted": True,
        "error": str(error),
        "returncode": returncode,
        "stderr": str(stderr)[-4000:],
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "action": "模型推理已熔断，等待修复后人工解除"
    }
    _write_json(FAULT_PATH, fault)
    return fault


def reset_fault():
    if FAULT_PATH.exists():
        FAULT_PATH.unlink()
    return True


def select_engine():
    for path in ENGINE_CANDIDATES:
        if path.is_file():
            return path
    return None


def status():
    engine = select_engine()
    fault = _read_fault()
    inference_verified = _probe_verified(engine)
    active_fault = bool(fault and not inference_verified)
    return {
        "provider": "llama.cpp",
        "engine": str(engine) if engine else None,
        "engine_exists": bool(engine),
        "model": str(MODEL_PATH),
        "model_exists": MODEL_PATH.is_file(),
        "ready_to_attempt": bool(engine and MODEL_PATH.is_file() and not active_fault),
        "inference_verified": inference_verified,
        "faulted": active_fault,
        "fault_recorded": bool(fault),
        "fault_bypassed_by_verified_probe": bool(fault and inference_verified),
        "fault": fault,
        "note": (
            "历史故障记录已保留；当前同一引擎和模型已通过真实低负载推理探针，使用保守参数恢复。"
            if fault and inference_verified else
            "模型已因推理崩溃熔断，禁止重复启动。"
            if active_fault else
            "文件存在不代表推理成功，尚未通过真实生成验收。"
        )
    }


def format_prompt(messages):
    """Render text-only messages using the native Qwen chat token format."""
    parts = []
    for item in messages:
        role = str(item.get("role", "user")).strip().lower()
        if role not in ("system", "user", "assistant"):
            role = "user"
        content = str(item.get("content", "")).strip()
        if not content:
            continue
        parts.append(f"<|im_start|>{role}\n{content}<|im_end|>")
    parts.append("<|im_start|>assistant\n")
    return "\n".join(parts)


def _log(event):
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(
            time.strftime("%Y-%m-%d %H:%M:%S")
            + " " + str(event) + "\n"
        )


def generate(messages, max_tokens=DEFAULT_TOKENS, timeout=DEFAULT_TIMEOUT):
    info = status()
    fault = _read_fault()
    if fault and not info.get("inference_verified"):
        return {
            "ok": False,
            "blocked": True,
            "error": "模型仍处于故障熔断状态；尚无匹配当前引擎和模型的成功探针。",
            "fault": fault
        }

    if not info["engine_exists"]:
        return {"ok": False, "error": "找不到 llama-cli 引擎"}
    if not info["model_exists"]:
        return {"ok": False, "error": "找不到 GGUF 模型文件"}

    max_tokens = max(1, min(int(max_tokens), 1024))
    timeout = max(10, min(int(timeout), 300))

    command = [
        str(select_engine()),
        "-m", str(MODEL_PATH),
        "-p", format_prompt(messages),
        "-n", str(max_tokens),
        "-c", str(DEFAULT_CONTEXT),
        "-t", str(DEFAULT_THREADS),
        "-b", str(DEFAULT_BATCH_SIZE),
        "-ub", str(DEFAULT_UBATCH_SIZE),
        "--flash-attn", "off",
        "--no-repack",
        "--no-warmup",
        "--no-display-prompt",
    ]

    _log("开始推理请求")

    try:
        result = subprocess.run(
            command,
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _log("推理超时")
        return {"ok": False, "error": f"模型推理超时（{timeout}秒）"}
    except Exception as exc:
        _log(f"模型启动异常：{type(exc).__name__}: {exc}")
        return {"ok": False, "error": f"模型启动异常：{type(exc).__name__}: {exc}"}

    output = (result.stdout or "").strip()
    error = (result.stderr or "").strip()
    code = result.returncode

    if code in (-11, 139):
        fault = record_fault(
            "检测到 SIGSEGV 段错误，模型推理进程崩溃",
            returncode=code,
            stderr=error
        )
        _log(f"熔断：SIGSEGV，退出码 {code}")
        return {
            "ok": False,
            "blocked": True,
            "error": "检测到模型段错误，已自动熔断，禁止重复启动。",
            "fault": fault
        }

    if code != 0:
        _log(f"模型异常退出：{code}")
        return {
            "ok": False,
            "error": f"模型进程异常退出，退出码 {code}",
            "stderr": error[-4000:],
            "stdout": output[-2000:]
        }

    if not output:
        return {
            "ok": False,
            "error": "模型进程退出码为 0，但没有生成文本",
            "stderr": error[-2000:]
        }

    engine_path = Path(info["engine"])
    _write_json(VERIFIED_PATH, {
        "engine": info["engine"],
        "model": info["model"],
        "engine_fingerprint": _file_fingerprint(engine_path),
        "model_fingerprint": _file_fingerprint(MODEL_PATH),
        "probe_ok": True,
        "verified_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "reply_chars": len(output)
    })
    _log("推理成功")
    return {
        "ok": True,
        "reply": output,
        "engine": info["engine"],
        "model": info["model"]
    }


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "reset-fault":
        reset_fault()
        print("模型熔断记录已清除")
    else:
        print(json.dumps(status(), ensure_ascii=False, indent=2))
