#!/data/data/com.termux/files/usr/bin/bash
set -u
A_ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
MAIN_REPO="$A_ROOT/vendor/stable-diffusion.cpp"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$A_ROOT/reports/ANIMEAI_A_BUILD_ENV_AUDIT_$STAMP.txt"
mkdir -p "$A_ROOT/reports"
exec > >(tee "$REPORT") 2>&1

section(){ printf '\n===== %s =====\n' "$1"; }
section "AnimeAI_A BUILD ENVIRONMENT AUDIT"
date
printf 'A_ROOT=%s\nMAIN_REPO=%s\n' "$A_ROOT" "$MAIN_REPO"

section "PATH VALIDATION"
if [ ! -d "$A_ROOT" ]; then echo "ERROR: A_ROOT_NOT_FOUND"; exit 2; fi
if [ ! -d "$MAIN_REPO/.git" ] && [ ! -f "$MAIN_REPO/.git" ]; then echo "ERROR: MAIN_REPO_NOT_GIT"; exit 2; fi

section "PINNED SOURCE COMMITS"
git -C "$MAIN_REPO" rev-parse HEAD 2>&1
git -C "$MAIN_REPO" status --short 2>&1
if [ -d "$MAIN_REPO/ggml" ]; then
  printf 'GGML='; git -C "$MAIN_REPO/ggml" rev-parse HEAD 2>&1
  git -C "$MAIN_REPO/ggml" status --short 2>&1
else echo "GGML_DIR_MISSING"; fi

section "SUBMODULE STATUS"
git -C "$MAIN_REPO" submodule status --recursive 2>&1 || true

section "DEPENDENCY DIRECTORIES"
for d in cutlass libwebp libwebm ggml; do
  p="$MAIN_REPO/$d"
  if [ -d "$p" ]; then
    echo "[$d] PRESENT"
    if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then
      printf 'commit='; git -C "$p" rev-parse HEAD 2>&1
      printf 'status='; git -C "$p" status --short 2>&1 | head -40
    else echo "git_metadata=NOT_FOUND"; fi
    find "$p" -maxdepth 2 \( -name CMakeLists.txt -o -name config.h -o -name '*.cmake' \) -type f 2>/dev/null | head -12
  else echo "[$d] MISSING"; fi
done

section "ANDROID AND BUILD ENVIRONMENT"
for v in ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_NDK_ROOT NDK_HOME JAVA_HOME CC CXX CMAKE_GENERATOR; do
  eval 'x=${'"$v"'-}'
  printf '%s=%s\n' "$v" "${x:-<unset>}"
done
for c in cmake ninja make clang clang++ git python python3 java; do
  printf '%-10s' "$c"; command -v "$c" 2>/dev/null || echo MISSING
done
cmake --version 2>&1 | head -2
ninja --version 2>&1 || true
clang --version 2>&1 | head -2 || true

section "NDK DISCOVERY"
for base in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${NDK_HOME:-}" "${ANDROID_HOME:-}/ndk" "${ANDROID_SDK_ROOT:-}/ndk" "$HOME/Android/Sdk/ndk" "$HOME"; do
  [ -n "${base:-}" ] && [ -d "$base" ] || continue
  find "$base" -maxdepth 5 -type f -name source.properties 2>/dev/null | head -20
done

section "OPENCL AND GPU RUNTIME EVIDENCE"
for p in /system/vendor/lib64 /vendor/lib64 /system/lib64 /data/data/com.termux/files/usr/lib "${PREFIX:-/data/data/com.termux/files/usr}/lib"; do
  [ -d "$p" ] || continue
  find "$p" -maxdepth 2 -type f \( -iname '*opencl*' -o -iname '*adreno*' -o -iname '*vulkan*' \) 2>/dev/null | head -40
done
for p in /system/vendor/etc /vendor/etc "${PREFIX:-/data/data/com.termux/files/usr}/include"; do
  [ -d "$p" ] || continue
  find "$p" -maxdepth 4 -type f \( -iname 'CL*.h' -o -iname 'opencl*.h' \) 2>/dev/null | head -30
done

section "EXISTING CMAKE BUILD TREES"
find "$MAIN_REPO" -maxdepth 6 -type f -name CMakeCache.txt -print 2>/dev/null | head -30 | while IFS= read -r f; do
  echo "--- $f"
  grep -E '^(CMAKE_BUILD_TYPE|CMAKE_GENERATOR|CMAKE_TOOLCHAIN_FILE|ANDROID_ABI|ANDROID_PLATFORM|CMAKE_ANDROID_NDK|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|GGML_OPENCL|GGML_VULKAN|SD_CUDA|SD_OPENCL)' "$f" 2>/dev/null | head -50
done

section "PROJECT BUILD OPTIONS"
for f in "$MAIN_REPO/CMakeLists.txt" "$MAIN_REPO/ggml/CMakeLists.txt" "$MAIN_REPO/README.md"; do
  [ -f "$f" ] || continue
  echo "--- $f"
  grep -Ein 'opencl|vulkan|adreno|webp|webm|cutlass|android|ndk|ggml' "$f" 2>/dev/null | head -80
done

section "SUMMARY"
echo "AUDIT_ONLY=YES"
echo "SOURCE_FILES_MODIFIED=NO"
echo "BUILD_EXECUTED=NO"
echo "INFERENCE_EXECUTED=NO"
echo "REPORT=$REPORT"
echo "RESULT=AUDIT_COMPLETE"

if command -v termux-share >/dev/null 2>&1; then
  cat "$REPORT" | termux-share -a send -c text/plain
else
  echo "WARNING: termux-share unavailable; report remains at $REPORT"
fi
