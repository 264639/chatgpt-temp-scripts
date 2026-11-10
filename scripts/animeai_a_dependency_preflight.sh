#!/data/data/com.termux/files/usr/bin/bash
set -u
A_ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
REPO="$A_ROOT/vendor/stable-diffusion.cpp"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$A_ROOT/reports/ANIMEAI_A_DEPENDENCY_PREFLIGHT_$STAMP.txt"
mkdir -p "$A_ROOT/reports"
exec > >(tee "$REPORT") 2>&1
section(){ printf '\n===== %s =====\n' "$1"; }
section "AnimeAI_A PRE-BUILD DEPENDENCY PREFLIGHT"
date
echo "REPO=$REPO"
if [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/.git" ]; then echo "FATAL=ENGINE_REPO_NOT_FOUND"; exit 2; fi

section "ENGINE AND WORKTREE"
echo "ENGINE_COMMIT=$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" status --short
echo "--- diff summary"
git -C "$REPO" diff --stat
echo "--- staged diff summary"
git -C "$REPO" diff --cached --stat

section "SUBMODULE DEFINITIONS"
if [ -f "$REPO/.gitmodules" ]; then cat "$REPO/.gitmodules"; else echo "NO .gitmodules"; fi
echo "--- recursive status"
git -C "$REPO" submodule status --recursive 2>&1 || true

section "ACTUAL THIRD PARTY DIRECTORIES"
for d in cutlass libwebp libwebm; do
 p="$REPO/thirdparty/$d"
 echo "[$d] path=$p"
 if [ -d "$p" ]; then
   echo "PRESENT"
   if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then
     echo "HEAD=$(git -C "$p" rev-parse HEAD 2>&1)"
     git -C "$p" status --short 2>&1 | head -50
   else echo "NO_GIT_METADATA"; fi
   find "$p" -maxdepth 2 -type f \( -name CMakeLists.txt -o -name '*.pc' -o -name '*.h' \) 2>/dev/null | head -15
 else echo "MISSING"; fi
done

section "SYSTEM PACKAGES VIA PKG-CONFIG"
if command -v pkg-config >/dev/null 2>&1; then
 for p in libwebp libwebpmux libwebpdemux libwebm OpenCL vulkan; do
   printf '%s: ' "$p"
   pkg-config --modversion "$p" 2>&1 || true
   printf '  cflags: '; pkg-config --cflags "$p" 2>/dev/null || true
   printf '  libs: '; pkg-config --libs "$p" 2>/dev/null || true
 done
else echo "pkg-config=MISSING"; fi

section "SYSTEM HEADERS AND LIBRARIES"
for f in \
 "$PREFIX/include/CL/cl.h" "$PREFIX/include/CL/opencl.h" \
 "$PREFIX/include/vulkan/vulkan.h" \
 "$PREFIX/include/webp/decode.h" "$PREFIX/include/webp/encode.h" \
 "$PREFIX/include/mkvmuxer/mkvmuxer.h" "$PREFIX/include/mkvparser/mkvparser.h"; do
 [ -f "$f" ] && echo "PRESENT $f" || echo "MISSING $f"
done
for f in "$PREFIX/lib/libwebp.so" "$PREFIX/lib/libwebpmux.so" "$PREFIX/lib/libwebm.so" "$PREFIX/lib/libOpenCL.so" "$PREFIX/lib/libvulkan.so"; do
 [ -e "$f" ] && ls -l "$f" || echo "MISSING $f"
done

section "NDK TOOLCHAIN"
NDK="$HOME/android-ndk-r29"
if [ -f "$NDK/source.properties" ]; then
 cat "$NDK/source.properties"
 [ -f "$NDK/build/cmake/android.toolchain.cmake" ] && echo "NDK_TOOLCHAIN=PRESENT" || echo "NDK_TOOLCHAIN=MISSING"
 for f in "$NDK/toolchains/llvm/prebuilt/linux-aarch64/bin/aarch64-linux-android24-clang" "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"; do
  [ -x "$f" ] && echo "COMPILER_PRESENT=$f"
 done
else echo "NDK_R29_NOT_FOUND"; fi

section "ENGINE CMAKE OPTIONS"
grep -nE '^(option\(|set\(SD_|if\(SD_|if \(SD_)' "$REPO/CMakeLists.txt" 2>/dev/null | head -180
section "GGML OPENCL OPTIONS"
grep -nEi 'OPENCL|VULKAN|option\(GGML_' "$REPO/ggml/CMakeLists.txt" "$REPO/ggml/src/CMakeLists.txt" 2>/dev/null | head -160

section "SUMMARY"
echo "READ_ONLY=YES"
echo "SUBMODULES_CHANGED=NO"
echo "SOURCE_MODIFIED=NO"
echo "BUILD_EXECUTED=NO"
echo "REPORT=$REPORT"
echo "RESULT=PREFLIGHT_COMPLETE"
if command -v termux-share >/dev/null 2>&1; then
 cat "$REPORT" | termux-share -a send -c text/plain
else echo "WARNING=termux-share unavailable"; fi
