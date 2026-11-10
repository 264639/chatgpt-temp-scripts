#!/data/data/com.termux/files/usr/bin/bash
set -u
ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
OUT="$ROOT/diagnostics"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT/opencl_public_library_probe_$STAMP.txt"
{
echo "===== AnimeAI_A OpenCL Public Library Probe ====="
echo "TIME=$(date '+%F %T %Z')"
echo "UID=$(id)"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH-}"
echo "LD_PRELOAD=${LD_PRELOAD-}"
echo
echo "===== 1. Linker namespace definitions and links ====="
if [ -r /linkerconfig/ld.config.txt ]; then
  awk '
    /^\[/{ if (show) {print; show=0} }
    /^\[name.default\]/ {show=1}
    /^\[name.sphal\]/ {show=1}
    /^\[name.vndk\]/ {show=1}
    /^\[name.rs\]/ {show=1}
    show {print}
  ' /linkerconfig/ld.config.txt | head -260
else
  echo "LINKER_CONFIG_NOT_READABLE"
fi
echo
echo "===== 2. Public library declarations ====="
for f in /vendor/etc/public.libraries.txt /system/vendor/etc/public.libraries.txt /system/etc/public.libraries.txt; do
  if [ -r "$f" ]; then
    echo "--- $f ---"
    cat "$f"
  fi
done
echo
echo "===== 3. Test dlopen by SONAME and identify actual loaded path ====="
python - <<'PY'
import ctypes, os
from ctypes.util import find_library
libdl=ctypes.CDLL("libdl.so")
class Dl_info(ctypes.Structure):
    _fields_=[("dli_fname",ctypes.c_char_p),("dli_fbase",ctypes.c_void_p),("dli_sname",ctypes.c_char_p),("dli_saddr",ctypes.c_void_p)]
dladdr=libdl.dladdr
dladdr.argtypes=[ctypes.c_void_p,ctypes.POINTER(Dl_info)]
dladdr.restype=ctypes.c_int
for name in ("libOpenCL.so","libOpenCL_adreno.so","libopencl_loader.so"):
    print("\nNAME:",name,"find_library:",find_library(name))
    try:
        h=ctypes.CDLL(name, mode=os.RTLD_NOW|os.RTLD_LOCAL)
        print("DLOPEN=SUCCESS", "handle=",hex(h._handle))
        for sym in ("clGetPlatformIDs","clIcdGetPlatformIDsKHR","qCLDrvAPI_clGetPlatformIDs"):
            try:
                fn=getattr(h,sym)
                info=Dl_info()
                ok=dladdr(ctypes.cast(fn,ctypes.c_void_p),ctypes.byref(info))
                print(" SYMBOL",sym,"FOUND","PATH=",info.dli_fname.decode(errors="replace") if ok and info.dli_fname else "?")
                if sym=="clGetPlatformIDs":
                    n=ctypes.c_uint()
                    rc=fn(0,None,ctypes.byref(n))
                    print("  PLATFORM_QUERY status=",rc,"count=",n.value)
            except Exception as e:
                print(" SYMBOL",sym,"NOT_FOUND",repr(e))
    except Exception as e:
        print("DLOPEN=FAILED",repr(e))
PY
echo
echo "===== 4. Termux clinfo result ====="
if command -v clinfo >/dev/null 2>&1; then
  clinfo --list 2>&1 | head -120 || clinfo 2>&1 | head -120
else
  echo "CLINFO_NOT_FOUND"
fi
echo
echo "===== 5. Vendor OpenCL loader dependency and symbol summary ====="
for f in /vendor/lib64/libOpenCL.so /vendor/lib64/libOpenCL_adreno.so /vendor/lib64/libopencl_loader.so; do
  [ -e "$f" ] || continue
  echo "--- $f ---"
  readelf -d "$f" 2>&1 | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' | head -80 || true
done
echo
echo "===== 6. Vulkan driver package paths and native libraries ====="
for d in /vendor/lib64/hw /vendor/lib64/egl /system/vendor/lib64/hw /system/vendor/lib64/egl /data/app; do
  [ -d "$d" ] || continue
  echo "--- $d ---"
  ls -la "$d" 2>/dev/null | grep -iE 'vulkan|adreno|gpu|qualcomm|gpudriver' | head -80 || true
done
echo
echo "===== 7. Vulkan device summary ====="
vulkaninfo --summary 2>&1 | grep -E 'GPU[0-9]|deviceName|deviceType|driverName|driverInfo|vendorID|ERROR|WARNING' | head -100 || true
echo
echo "===== END ====="
echo "Read-only probe. No source/build/system files modified."
echo "REPORT=$REPORT"
} > "$REPORT" 2>&1
cat "$REPORT" | termux-share -a send -c text/plain
