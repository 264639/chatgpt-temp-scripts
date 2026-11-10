#!/data/data/com.termux/files/usr/bin/bash
set -u

ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
ENGINE="$ROOT/vendor/stable-diffusion.cpp/build-android-opencl/bin/sd-server"
OUT="$ROOT/diagnostics"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT/opencl_linker_namespace_audit_$STAMP.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
echo "===== AnimeAI_A Android Linker Namespace Audit ====="
echo "TIME=$(date '+%F %T %Z')"
echo "ROOT=$ROOT"
echo
echo "===== 1. Runtime identity and app process ====="
uname -a
id
getprop ro.build.version.sdk 2>/dev/null || true
getprop ro.gfx.driver.1 2>/dev/null || true
getprop ro.product.cpu.abi 2>/dev/null || true
echo "TERMUX_PACKAGE=$(getprop ro.build.version.release 2>/dev/null || true)"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH-}"
echo "LD_PRELOAD=${LD_PRELOAD-}"
echo
echo "===== 2. Android linker configuration visibility ====="
for f in /linkerconfig/ld.config.txt /system/etc/ld.config.txt /system/etc/public.libraries.txt /system/etc/public.libraries-arm64.txt /vendor/etc/public.libraries.txt /vendor/etc/public.libraries-arm64.txt /system/vendor/etc/public.libraries.txt; do
  if [ -r "$f" ]; then
    echo "--- $f (matching lines) ---"
    grep -inE 'namespace|permitted.paths|search.paths|link.(to|namespaces)|OpenCL|adreno|qcom|gpu' "$f" 2>/dev/null | head -100 || true
  else
    echo "--- $f NOT_READABLE_OR_ABSENT ---"
  fi
done
echo
echo "===== 3. GPU driver package registration ====="
pm list packages 2>/dev/null | grep -iE 'qualcomm|qti|gpu|adreno' | head -80 || true
for p in com.qualcomm.qti.gpudrivers.pineapple.api34 com.qualcomm.qti.gpudrivers; do
  echo "--- package $p ---"
  pm path "$p" 2>&1 || true
  dumpsys package "$p" 2>/dev/null | grep -iE 'versionName|versionCode|codePath|nativeLibraryDir|primaryCpuAbi|enabled=' | head -30 || true
done
echo
echo "===== 4. Vendor OpenCL ELF metadata and dependencies ====="
for f in /vendor/lib64/libOpenCL.so /vendor/lib64/libOpenCL_adreno.so /vendor/lib64/libopencl_loader.so /system/vendor/lib64/libOpenCL.so /system/vendor/lib64/libOpenCL_adreno.so /vendor/lib/libOpenCL.so /vendor/lib/libOpenCL_adreno.so; do
  [ -e "$f" ] || continue
  echo "--- $f ---"
  ls -l "$f" 2>&1 || true
  readlink -f "$f" 2>&1 || true
  file "$f" 2>&1 || true
  if command -v readelf >/dev/null 2>&1; then
    readelf -d "$f" 2>&1 | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' | head -80 || true
    readelf -Ws "$f" 2>/dev/null | grep -E 'clGetPlatformIDs|clGetDeviceIDs|clIcdGetPlatformIDsKHR|android_get_exported_namespace|android_dlopen_ext' | head -30 || true
  fi
done
echo
echo "===== 5. Termux OpenCL loader ELF metadata ====="
for f in "$PREFIX/lib/libOpenCL.so" "$PREFIX/lib/libggml-opencl.so"; do
  [ -e "$f" ] || continue
  echo "--- $f ---"
  ls -l "$f"
  readelf -d "$f" 2>&1 | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' | head -80 || true
  readelf -Ws "$f" 2>/dev/null | grep -E 'clGetPlatformIDs|clIcdGetPlatformIDsKHR' | head -30 || true
done
echo
echo "===== 6. Public libdl namespace API availability ====="
python - <<'PY'
import ctypes
for name in ("libdl.so", "libc.so"):
    try:
        lib=ctypes.CDLL(name)
        print("LIB", name, "LOAD=OK")
        for sym in ("android_dlopen_ext", "android_get_exported_namespace", "android_create_namespace", "dlopen", "dlsym"):
            try:
                getattr(lib,sym)
                print(" SYMBOL",sym,"EXPORTED")
            except Exception:
                print(" SYMBOL",sym,"NOT_EXPORTED")
    except Exception as e:
        print("LIB",name,"ERROR",repr(e))
PY
echo
echo "===== 7. Available GPU/OpenCL inspection commands ====="
for c in vulkaninfo clinfo eglinfo dumpsys cmd; do
  command -v "$c" 2>/dev/null || true
done
if command -v vulkaninfo >/dev/null 2>&1; then
  echo "--- vulkaninfo --summary (first 100 lines) ---"
  vulkaninfo --summary 2>&1 | head -100 || true
fi
echo
echo "===== 8. sd-server device list ====="
if [ -x "$ENGINE" ]; then
  "$ENGINE" --list-devices 2>&1 || true
else
  echo "ENGINE_NOT_FOUND=$ENGINE"
fi
echo
echo "===== 9. Relevant filesystem access checks ====="
for p in /vendor/lib64 /vendor/lib64/libOpenCL.so /vendor/lib64/libOpenCL_adreno.so /system/vendor/lib64 /system/vendor/lib64/libOpenCL.so /system/vendor/lib64/libOpenCL_adreno.so /apex/com.android.runtime/lib64/bionic; do
  if [ -r "$p" ]; then echo "READABLE $p"; else echo "NOT_READABLE $p"; fi
done
echo
echo "===== END ====="
echo "Read-only audit. No source/build/system files modified."
echo "REPORT=$REPORT"
} > "$REPORT" 2>&1

cat "$REPORT" | termux-share -a send -c text/plain
