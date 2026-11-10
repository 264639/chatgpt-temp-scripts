#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
BUILD="$ROOT/vendor/stable-diffusion.cpp/build-android-opencl"
SERVER="$BUILD/bin/sd-server"
OUTDIR="$ROOT/diagnostics"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/opencl_runtime_audit_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "===== AnimeAI_A OpenCL Runtime Audit ====="
  echo "TIME=$(date '+%F %T %Z')"
  echo "ROOT=$ROOT"
  echo "BUILD=$BUILD"
  echo

  echo "===== 1. Environment ====="
  echo "TERMUX_PREFIX=${PREFIX:-unknown}"
  echo "ARCH=$(uname -m)"
  echo "KERNEL=$(uname -sr)"
  for key in ro.product.model ro.soc.model ro.hardware; do
    printf '%s=' "$key"
    getprop "$key" 2>/dev/null || true
  done
  echo

  echo "===== 2. Build artifact ====="
  if [ -x "$SERVER" ]; then
    ls -lh "$SERVER"
    sha256sum "$SERVER"
    echo "SD_SERVER_EXECUTABLE=YES"
  else
    echo "SD_SERVER_EXECUTABLE=NO"
  fi
  echo

  echo "===== 3. OpenCL libraries and configuration ====="
  for f in \
    "$PREFIX/lib/libOpenCL.so" \
    /vendor/lib64/libOpenCL.so \
    /vendor/lib/libOpenCL.so \
    /system/vendor/lib64/libOpenCL.so \
    /system/vendor/lib/libOpenCL.so \
    /vendor/etc/OpenCL/vendors \
    /system/vendor/etc/OpenCL/vendors; do
    if [ -e "$f" ]; then
      ls -ld "$f"
      if [ -d "$f" ]; then find "$f" -maxdepth 2 -type f -print; fi
    fi
  done
  echo

  echo "===== 4. OpenCL platform/device enumeration ====="
  python3 - <<'PY'
import ctypes, ctypes.util, os
from pathlib import Path

candidates = []
found = ctypes.util.find_library("OpenCL")
if found:
    candidates.append(found)
for p in [
    os.path.join(os.environ.get("PREFIX", ""), "lib/libOpenCL.so"),
    "/vendor/lib64/libOpenCL.so",
    "/vendor/lib/libOpenCL.so",
    "/system/vendor/lib64/libOpenCL.so",
    "/system/vendor/lib/libOpenCL.so",
]:
    if p and Path(p).exists() and p not in candidates:
        candidates.append(p)

print("LIBRARY_CANDIDATES:", candidates or "NONE")
lib = None
loaded = None
for p in candidates:
    try:
        lib = ctypes.CDLL(p)
        loaded = p
        break
    except Exception as e:
        print("LOAD_FAILED:", p, repr(e))
if lib is None:
    print("OPENCL_LIBRARY_LOAD=FAILED")
    raise SystemExit(0)
print("OPENCL_LIBRARY_LOAD=SUCCESS", loaded)

cl_uint = ctypes.c_uint
cl_int = ctypes.c_int
size_t = ctypes.c_size_t
cl_platform_id = ctypes.c_void_p
cl_device_id = ctypes.c_void_p

def setup(name, restype, argtypes):
    fn = getattr(lib, name)
    fn.restype = restype
    fn.argtypes = argtypes
    return fn

get_platform_ids = setup("clGetPlatformIDs", cl_int, [cl_uint, ctypes.POINTER(cl_platform_id), ctypes.POINTER(cl_uint)])
get_platform_info = setup("clGetPlatformInfo", cl_int, [cl_platform_id, cl_uint, size_t, ctypes.c_void_p, ctypes.POINTER(size_t)])
get_device_ids = setup("clGetDeviceIDs", cl_int, [cl_platform_id, ctypes.c_ulong, cl_uint, ctypes.POINTER(cl_device_id), ctypes.POINTER(cl_uint)])
get_device_info = setup("clGetDeviceInfo", cl_int, [cl_device_id, cl_uint, size_t, ctypes.c_void_p, ctypes.POINTER(size_t)])

def info(fn, obj, key):
    n = size_t()
    rc = fn(obj, key, 0, None, ctypes.byref(n))
    if rc != 0 or n.value == 0:
        return "ERROR_" + str(rc)
    buf = ctypes.create_string_buffer(n.value)
    rc = fn(obj, key, n.value, buf, None)
    if rc != 0:
        return "ERROR_" + str(rc)
    return buf.value.decode("utf-8", "replace")

count = cl_uint()
rc = get_platform_ids(0, None, ctypes.byref(count))
print("clGetPlatformIDs_count_status:", rc, "platform_count:", count.value)
if rc != 0 or count.value == 0:
    print("OPENCL_PLATFORM_ENUMERATION=FAILED")
    raise SystemExit(0)
platforms = (cl_platform_id * count.value)()
rc = get_platform_ids(count.value, platforms, None)
print("clGetPlatformIDs_list_status:", rc)
for i, p in enumerate(platforms):
    print(f"PLATFORM_{i}_NAME:", info(get_platform_info, p, 0x0902))
    print(f"PLATFORM_{i}_VENDOR:", info(get_platform_info, p, 0x0903))
    print(f"PLATFORM_{i}_VERSION:", info(get_platform_info, p, 0x0901))
    ndev = cl_uint()
    drc = get_device_ids(p, 0xFFFFFFFF, 0, None, ctypes.byref(ndev))
    print(f"PLATFORM_{i}_DEVICE_COUNT_STATUS:", drc, "count:", ndev.value)
    if drc != 0 or ndev.value == 0:
        continue
    devices = (cl_device_id * ndev.value)()
    drc = get_device_ids(p, 0xFFFFFFFF, ndev.value, devices, None)
    print(f"PLATFORM_{i}_DEVICE_LIST_STATUS:", drc)
    for j, d in enumerate(devices):
        print(f"DEVICE_{i}_{j}_NAME:", info(get_device_info, d, 0x102B))
        print(f"DEVICE_{i}_{j}_VENDOR:", info(get_device_info, d, 0x102C))
        print(f"DEVICE_{i}_{j}_VERSION:", info(get_device_info, d, 0x102F))
        print(f"DEVICE_{i}_{j}_DRIVER:", info(get_device_info, d, 0x102D))
        dtype = ctypes.c_ulong()
        trc = get_device_info(d, 0x1000, ctypes.sizeof(dtype), ctypes.byref(dtype), None)
        print(f"DEVICE_{i}_{j}_TYPE_STATUS:", trc, "type_bits:", hex(dtype.value))
print("OPENCL_PLATFORM_ENUMERATION=SUCCESS")
PY
  echo

  echo "===== 5. sd-server non-invasive startup probe ====="
  if [ -x "$SERVER" ]; then
    python3 - "$SERVER" <<'PY'
import subprocess, sys
p = sys.argv[1]
try:
    r = subprocess.run([p, "--help"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, timeout=15)
    print("EXIT_CODE:", r.returncode)
    print((r.stdout or "")[:6000])
except subprocess.TimeoutExpired as e:
    print("PROBE_TIMEOUT_AFTER_15_SECONDS")
    if e.stdout:
        print(str(e.stdout)[:3000])
except Exception as e:
    print("PROBE_ERROR:", repr(e))
PY
  else
    echo "SKIPPED: sd-server executable missing"
  fi
  echo

  echo "===== 6. Audit conclusion ====="
  echo "This audit is read-only with respect to source and build files."
  echo "It does not launch image generation, load a model, or modify project configuration."
  echo "OpenCL runtime/device status must be judged from the enumeration results above."
  echo "REPORT=$REPORT"
} > "$REPORT" 2>&1

echo "AUDIT_REPORT=$REPORT"
cat "$REPORT" | termux-share -a send -c text/plain
