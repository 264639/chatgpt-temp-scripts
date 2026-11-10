#!/data/data/com.termux/files/usr/bin/bash
set -u
ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
BIN="$ROOT/vendor/stable-diffusion.cpp/build-android-opencl/bin/sd-server"
OUT="$ROOT/diagnostics"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT/opencl_vendor_platform_device_probe_$STAMP.txt"
{
echo "===== AnimeAI_A Vendor OpenCL Platform and Device Probe ====="
echo "TIME=$(date '+%F %T %Z')"
echo "ROOT=$ROOT"
echo "BIN=$BIN"
echo
echo "===== 1. Vendor OpenCL platform/device enumeration ====="
LD_LIBRARY_PATH=/vendor/lib64 python - <<'PY'
import ctypes
try:
    cl=ctypes.CDLL("libOpenCL.so")
    def info_string(fn, obj, key):
        n=ctypes.c_size_t()
        rc=fn(obj,key,0,None,ctypes.byref(n))
        if rc != 0 or not n.value: return f"<query error {rc}>"
        b=ctypes.create_string_buffer(n.value)
        rc=fn(obj,key,n.value,b,None)
        return b.value.decode(errors="replace") if rc==0 else f"<query error {rc}>"
    np=ctypes.c_uint()
    rc=cl.clGetPlatformIDs(0,None,ctypes.byref(np))
    print("PLATFORM_STATUS",rc,"PLATFORM_COUNT",np.value)
    if rc != 0: raise SystemExit(0)
    ps=(ctypes.c_void_p*np.value)()
    rc=cl.clGetPlatformIDs(np.value,ps,None)
    print("PLATFORM_FETCH_STATUS",rc)
    for pi,p in enumerate(ps):
        print(f"PLATFORM[{pi}]")
        for k,n in [(0x0900,"NAME"),(0x0901,"VENDOR"),(0x0902,"VERSION"),(0x0903,"PROFILE"),(0x0904,"EXTENSIONS")]:
            print(" ",n,info_string(cl.clGetPlatformInfo,p,k))
        nd=ctypes.c_uint()
        rc=cl.clGetDeviceIDs(p,0xFFFFFFFF,0,None,ctypes.byref(nd))
        print(" DEVICE_ENUM_STATUS",rc,"DEVICE_COUNT",nd.value)
        if rc != 0: continue
        ds=(ctypes.c_void_p*nd.value)()
        rc=cl.clGetDeviceIDs(p,0xFFFFFFFF,nd.value,ds,None)
        print(" DEVICE_FETCH_STATUS",rc)
        for di,d in enumerate(ds):
            print(f" DEVICE[{di}]")
            for k,n in [(0x1000,"TYPE"),(0x102B,"NAME"),(0x102C,"VENDOR"),(0x102D,"DRIVER_VERSION"),(0x102F,"DEVICE_VERSION"),(0x1030,"EXTENSIONS")]:
                print("  ",n,info_string(cl.clGetDeviceInfo,d,k))
            for k,n,typ in [(0x1002,"MAX_COMPUTE_UNITS",ctypes.c_uint),(0x101F,"GLOBAL_MEM_SIZE",ctypes.c_ulonglong),(0x1003,"MAX_WORK_ITEM_DIMENSIONS",ctypes.c_uint)]:
                v=typ(); r=cl.clGetDeviceInfo(d,k,ctypes.sizeof(v),ctypes.byref(v),None)
                print("  ",n,v.value if r==0 else f"<query error {r}>")
except Exception as e:
    print("PYTHON_OPENCL_ERROR",repr(e))
PY
echo
echo "===== 2. sd-server device enumeration with vendor loader ====="
if [ -x "$BIN" ]; then
  echo "COMMAND=LD_LIBRARY_PATH=/vendor/lib64 $BIN --list-devices"
  LD_LIBRARY_PATH=/vendor/lib64 timeout 30 "$BIN" --list-devices 2>&1
  echo "SD_SERVER_EXIT=$?"
else
  echo "SD_SERVER_NOT_FOUND"
fi
echo
echo "===== 3. clinfo with vendor loader ====="
if command -v clinfo >/dev/null 2>&1; then
  LD_LIBRARY_PATH=/vendor/lib64 timeout 30 clinfo --list 2>&1
  echo "CLINFO_EXIT=$?"
else
  echo "CLINFO_NOT_INSTALLED"
fi
echo
echo "===== 4. Android system Vulkan loader test ====="
if command -v vulkaninfo >/dev/null 2>&1; then
  echo "--- LD_LIBRARY_PATH=/system/lib64 vulkaninfo --summary ---"
  LD_LIBRARY_PATH=/system/lib64 timeout 40 vulkaninfo --summary 2>&1 | head -160
  echo "VULKANINFO_PIPESTATUS=${PIPESTATUS[*]}"
else
  echo "VULKANINFO_NOT_INSTALLED"
fi
echo
echo "===== 5. End ====="
echo "Read-only runtime probe. No source/build/system files modified."
echo "REPORT=$REPORT"
} > "$REPORT" 2>&1
cat "$REPORT" | termux-share -a send -c text/plain
