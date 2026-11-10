#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
BUILD="$ROOT/vendor/stable-diffusion.cpp/build-android-opencl"
SERVER="$BUILD/bin/sd-server"
REPORT="$ROOT/diagnostics/opencl_driver_discovery_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$(dirname "$REPORT")"

{
  echo "===== AnimeAI_A OpenCL Driver Discovery ====="
  echo "TIME=$(date '+%F %T %Z')"
  echo "ROOT=$ROOT"
  echo

  echo "===== 1. Vendor OpenCL ICD registration ====="
  for d in /vendor/etc/OpenCL/vendors /system/vendor/etc/OpenCL/vendors /odm/etc/OpenCL/vendors /etc/OpenCL/vendors "$PREFIX/etc/OpenCL/vendors"; do
    echo "--- $d ---"
    if [ -d "$d" ]; then
      ls -la "$d"
      find "$d" -maxdepth 2 -type f -print -exec sh -c 'echo "[CONTENT] $1"; cat "$1" 2>/dev/null || true' sh {} \;
    else
      echo "NOT_FOUND"
    fi
  done
  echo

  echo "===== 2. Qualcomm/Adreno OpenCL driver libraries ====="
  find /vendor/lib64 /vendor/lib /system/vendor/lib64 /system/vendor/lib /odm/lib64 /odm/lib "$PREFIX/lib" \
    -maxdepth 2 -type f \( -iname '*opencl*' -o -iname '*adreno*' -o -iname '*llvm*' -o -iname '*qcom*' \) \
    -print 2>/dev/null | sort -u
  echo

  echo "===== 3. Relevant Android properties ====="
  getprop | grep -i -E 'opencl|adreno|gpu|qcom|soc' || true
  echo

  echo "===== 4. sd-server backend device list ====="
  if [ -x "$SERVER" ]; then
    set +e
    "$SERVER" --list-devices 2>&1
    echo "LIST_DEVICES_EXIT=$?"
    set -e
  else
    echo "SD_SERVER_MISSING"
  fi
  echo

  echo "===== 5. OpenCL loader environment ====="
  env | grep -i -E 'opencl|ocl|icd|cl_' || true
  echo

  echo "===== 6. Direct ICD candidate probes ====="
  python3 - <<'PY'
import ctypes, os
from pathlib import Path

paths = [
    "/vendor/lib64/libOpenCL.so",
    "/vendor/lib/libOpenCL.so",
    "/system/vendor/lib64/libOpenCL.so",
    "/system/vendor/lib/libOpenCL.so",
    os.path.join(os.environ.get("PREFIX",""),"lib/libOpenCL.so"),
]
for p in paths:
    if not p or not Path(p).exists():
        continue
    print("\nLIBRARY:", p)
    try:
        lib = ctypes.CDLL(p)
        fn = lib.clGetPlatformIDs
        fn.restype = ctypes.c_int
        fn.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
        n = ctypes.c_uint()
        rc = fn(0, None, ctypes.byref(n))
        print("LOAD=SUCCESS", "PLATFORM_STATUS=", rc, "COUNT=", n.value)
    except Exception as e:
        print("LOAD_OR_QUERY_FAILED:", repr(e))
PY
  echo

  echo "===== 7. Build configuration evidence ====="
  CACHE="$BUILD/CMakeCache.txt"
  if [ -f "$CACHE" ]; then
    grep -E '^(GGML_OPENCL|GGML_OPENCL_USE_ADRENO_KERNELS|CMAKE_BUILD_TYPE|CMAKE_ANDROID_ARCH_ABI):' "$CACHE" || true
  else
    echo "CMAKE_CACHE_MISSING"
  fi
  echo
  echo "===== END ====="
  echo "Read-only discovery. No source/build files modified."
  echo "REPORT=$REPORT"
} > "$REPORT" 2>&1

echo "AUDIT_REPORT=$REPORT"
cat "$REPORT" | termux-share -a send -c text/plain
