#!/data/data/com.termux/files/usr/bin/bash
set -u
ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
BIN="$ROOT/vendor/stable-diffusion.cpp/build-android-opencl/bin/sd-server"
REPORT_DIR="$ROOT/diagnostics"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/opencl_vendor_runtime_device_probe_$(date +%Y%m%d_%H%M%S).txt"
exec > >(tee "$REPORT") 2>&1

echo "===== AnimeAI_A Vendor OpenCL Runtime Device Probe ====="
date
id
echo "PREFIX=$PREFIX"
echo "ROOT=$ROOT"
echo
echo "===== 1. Vendor OpenCL library identity ====="
ls -l /vendor/lib64/libOpenCL.so /vendor/lib64/libOpenCL_adreno.so 2>&1 || true
readelf -d /vendor/lib64/libOpenCL.so 2>/dev/null | grep -E 'SONAME|NEEDED' || true
echo
echo "===== 2. Isolated Python OpenCL platform/device enumeration ====="
echo "Only this child process receives vendor-first LD_LIBRARY_PATH."
env LD_LIBRARY_PATH="/vendor/lib64:$PREFIX/lib" python3 - <<'PY'
import ctypes, os, sys
from ctypes import c_uint, c_int, c_ulong, c_size_t, c_void_p, c_char, POINTER, byref, create_string_buffer
print("LD_LIBRARY_PATH=" + os.environ.get("LD_LIBRARY_PATH",""))
try:
    cl = ctypes.CDLL("libOpenCL.so")
    print("LIBRARY_LOAD=OK")
except Exception as e:
    print("LIBRARY_LOAD=FAIL", repr(e)); sys.exit(2)

cl.clGetPlatformIDs.argtypes=[c_uint, POINTER(c_void_p), POINTER(c_uint)]
cl.clGetPlatformIDs.restype=c_int
n=c_uint(0)
rc=cl.clGetPlatformIDs(0,None,byref(n))
print("PLATFORM_QUERY_STATUS=%d PLATFORM_COUNT=%d"%(rc,n.value))
if rc != 0 or n.value == 0: sys.exit(3)
platforms=(c_void_p*n.value)()
rc=cl.clGetPlatformIDs(n.value,platforms,None)
print("PLATFORM_FETCH_STATUS=%d"%rc)
if rc != 0: sys.exit(4)

def info(fn, obj, key):
    size=c_size_t(0)
    r=fn(obj,key,0,None,byref(size))
    if r != 0 or size.value == 0: return "INFO_ERROR_%d"%r
    buf=create_string_buffer(size.value)
    r=fn(obj,key,size.value,buf,None)
    if r != 0: return "INFO_ERROR_%d"%r
    return buf.value.decode("utf-8","replace")

cl.clGetPlatformInfo.argtypes=[c_void_p,c_uint,c_size_t,c_void_p,POINTER(c_size_t)]
cl.clGetPlatformInfo.restype=c_int
cl.clGetDeviceIDs.argtypes=[c_void_p,c_ulong,c_uint,POINTER(c_void_p),POINTER(c_uint)]
cl.clGetDeviceIDs.restype=c_int
cl.clGetDeviceInfo.argtypes=[c_void_p,c_uint,c_size_t,c_void_p,POINTER(c_size_t)]
cl.clGetDeviceInfo.restype=c_int
# OpenCL constants
CL_PLATFORM_PROFILE=0x0900; CL_PLATFORM_VERSION=0x0901
CL_PLATFORM_NAME=0x0902; CL_PLATFORM_VENDOR=0x0903
CL_DEVICE_TYPE_ALL=0xFFFFFFFF
CL_DEVICE_NAME=0x102B; CL_DEVICE_VENDOR=0x102C
CL_DEVICE_VERSION=0x102F; CL_DRIVER_VERSION=0x102D
CL_DEVICE_MAX_COMPUTE_UNITS=0x1002; CL_DEVICE_GLOBAL_MEM_SIZE=0x101F
total=0
for i,p in enumerate(platforms):
    print("\nPLATFORM[%d]"%i)
    print(" NAME="+info(cl.clGetPlatformInfo,p,CL_PLATFORM_NAME))
    print(" VENDOR="+info(cl.clGetPlatformInfo,p,CL_PLATFORM_VENDOR))
    print(" VERSION="+info(cl.clGetPlatformInfo,p,CL_PLATFORM_VERSION))
    dn=c_uint(0)
    dr=cl.clGetDeviceIDs(p,CL_DEVICE_TYPE_ALL,0,None,byref(dn))
    print(" DEVICE_QUERY_STATUS=%d DEVICE_COUNT=%d"%(dr,dn.value))
    if dr != 0 or dn.value == 0: continue
    devs=(c_void_p*dn.value)()
    dr=cl.clGetDeviceIDs(p,CL_DEVICE_TYPE_ALL,dn.value,devs,None)
    print(" DEVICE_FETCH_STATUS=%d"%dr)
    if dr != 0: continue
    for j,d in enumerate(devs):
        total += 1
        print("  DEVICE[%d]"%j)
        for label,key in [("NAME",CL_DEVICE_NAME),("VENDOR",CL_DEVICE_VENDOR),("VERSION",CL_DEVICE_VERSION),("DRIVER_VERSION",CL_DRIVER_VERSION)]:
            print("   %s=%s"%(label,info(cl.clGetDeviceInfo,d,key)))
        for label,key,typ in [("COMPUTE_UNITS",CL_DEVICE_MAX_COMPUTE_UNITS,c_uint),("GLOBAL_MEM_BYTES",CL_DEVICE_GLOBAL_MEM_SIZE,c_ulong)]:
            value=typ(0); r=cl.clGetDeviceInfo(d,key,ctypes.sizeof(value),byref(value),None)
            print("   %s=%s STATUS=%d"%(label,value.value,r))
print("\nTOTAL_DEVICES=%d"%total)
sys.exit(0 if total else 5)
PY
PY_RC=$?
echo "PYTHON_DEVICE_PROBE_EXIT=$PY_RC"
echo
echo "===== 3. stable-diffusion.cpp device listing with vendor-first loader ====="
if [ -x "$BIN" ]; then
  env LD_LIBRARY_PATH="/vendor/lib64:$PREFIX/lib" "$BIN" --list-devices 2>&1
  SD_RC=$?
  echo "SD_LIST_DEVICES_EXIT=$SD_RC"
else
  echo "SD_SERVER_NOT_FOUND=$BIN"
  SD_RC=127
fi
echo
echo "===== 4. Summary ====="
echo "PYTHON_DEVICE_PROBE_EXIT=$PY_RC"
echo "SD_LIST_DEVICES_EXIT=$SD_RC"
echo "REPORT=$REPORT"
echo "Read-only probe. No source, build, environment, or system files modified."
termux-share -a send -c text/plain < "$REPORT"
