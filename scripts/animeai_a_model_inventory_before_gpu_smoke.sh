#!/data/data/com.termux/files/usr/bin/bash
set -u
PROJECT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
ENGINE="$PROJECT/vendor/stable-diffusion.cpp"
BUILD="$ENGINE/build-android-opencl"
BIN="$BUILD/bin/sd-server"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$PROJECT/diagnostics/model_inventory_before_gpu_smoke_${STAMP}.txt"
mkdir -p "$PROJECT/diagnostics"
{
  echo "===== AnimeAI_A Model Inventory Before GPU Smoke Test ====="
  date
  echo "PROJECT=$PROJECT"
  echo
  echo "===== 1. Build artifact ====="
  if [ -x "$BIN" ]; then
    ls -lh "$BIN"
    sha256sum "$BIN"
    echo "--- device listing with vendor OpenCL path ---"
    LD_LIBRARY_PATH=/vendor/lib64 "$BIN" --list-devices 2>&1
    echo "DEVICE_LIST_EXIT=$?"
  else
    echo "SD_SERVER_MISSING=$BIN"
  fi
  echo
  echo "===== 2. Model registry and model-related directories ====="
  for p in "$PROJECT/models" "$ENGINE/models" "$HOME/models" "$HOME/Models" "$HOME/storage/shared/Download" "$HOME/storage/downloads"; do
    if [ -e "$p" ]; then
      echo "--- $p ---"
      ls -lah "$p" 2>&1 | head -80
    fi
  done
  echo
  echo "===== 3. Candidate model files ====="
  : > "$REPORT.candidates.tmp"
  SEARCH_DIRS=()
  for p in "$PROJECT" "$HOME/models" "$HOME/Models" "$HOME/storage/shared/Download" "$HOME/storage/downloads"; do
    [ -d "$p" ] && SEARCH_DIRS+=("$p")
  done
  if [ "${#SEARCH_DIRS[@]}" -gt 0 ]; then
    find "${SEARCH_DIRS[@]}" -type f \( \
      -iname '*.safetensors' -o -iname '*.ckpt' -o -iname '*.pt' -o \
      -iname '*.pth' -o -iname '*.onnx' -o -iname '*.gguf' -o \
      -iname '*.bin' -o -iname '*.ggml' \
    \) -printf '%s\t%p\n' 2>/dev/null | sort -nr > "$REPORT.candidates.tmp"
    if [ -s "$REPORT.candidates.tmp" ]; then
      awk -F '\t' '{printf "SIZE_BYTES=%s  PATH=%s\n", $1, $2}' "$REPORT.candidates.tmp"
    else
      echo "NO_CANDIDATE_MODEL_FILES_FOUND"
    fi
  else
    echo "NO_SEARCH_DIRECTORIES_FOUND"
  fi
  echo
  echo "===== 4. Model configuration hints ====="
  for d in "$PROJECT" "$ENGINE"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 4 -type f \( -iname '*model*registry*.json' -o -iname '*config*.json' -o -iname 'README*' \) -print 2>/dev/null | head -80
  done
  echo
  echo "===== 5. Storage and memory snapshot ====="
  df -h "$HOME" 2>&1
  grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo 2>/dev/null
  echo
  echo "===== END ====="
  echo "Read-only inventory: no model, source, build, or system files were changed."
} > "$REPORT" 2>&1
rm -f "$REPORT.candidates.tmp"
echo "报告：$REPORT"
cat "$REPORT" | termux-share -a send -c text/plain
