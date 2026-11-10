#!/data/data/com.termux/files/usr/bin/bash
set -u
ROOT="$HOME/AnimeAI_A_SOURCE_FINAL_20261110/AnimeAI_A"
OUT="$ROOT/diagnostics"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUT/android_gpu_loader_path_audit_$STAMP.txt"
{
echo "===== AnimeAI_A Android GPU Loader Path Audit ====="
echo "TIME=$(date '+%F %T %Z')"
echo "UID=$(id)"
echo
echo "===== 1. Linker config namespace section map ====="
if [ -r /linkerconfig/ld.config.txt ]; then
  grep -nE '^\[|^namespace\.(default|sphal|vndk)\.(links|link\.to|search\.paths|permitted\.paths|isolated|visible)|^namespace\.(default|sphal|vndk)\.link\.' /linkerconfig/ld.config.txt | head -300
  echo "--- full default/sphal/vndk relevant stanzas ---"
  awk '
    /^\[/ {keep=($0 ~ /name\.(default|sphal|vndk)/)}
    keep {print}
  ' /linkerconfig/ld.config.txt | head -500
else
  echo "LINKER_CONFIG_NOT_READABLE"
fi
echo
echo "===== 2. Vulkan loader files and driver manifests ====="
for f in "$PREFIX/lib/libvulkan.so" /system/lib64/libvulkan.so /vendor/lib64/libvulkan.so /vendor/lib64/hw/vulkan.adreno.so; do
  [ -e "$f" ] || continue
  echo "--- $f ---"
  ls -l "$f"
  readlink -f "$f" 2>&1 || true
  readelf -d "$f" 2>&1 | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' | head -60 || true
done
for d in /vendor/etc/vulkan /vendor/etc/vulkan/icd.d /odm/etc/vulkan /system/etc/vulkan /system/vendor/etc/vulkan /vendor/etc; do
  [ -d "$d" ] || continue
  echo "--- manifests in $d ---"
  find "$d" -maxdepth 3 -type f 2>/dev/null | grep -iE 'vulkan|icd|json' | head -100 | while read -r f; do
    echo "FILE=$f"
    head -80 "$f" 2>/dev/null || true
  done
done
echo
echo "===== 3. GPU driver package properties ====="
getprop | grep -iE 'gpu.*driver|driver.*gpu|vulkan|adreno|graphics' | head -160 || true
echo
echo "===== 4. Vulkan loader selection via dladdr ====="
python - <<'PY'
import ctypes, os
libdl=ctypes.CDLL("libdl.so")
class Info(ctypes.Structure):
    _fields_=[("fname",ctypes.c_char_p),("base",ctypes.c_void_p),("sname",ctypes.c_char_p),("saddr",ctypes.c_void_p)]
dladdr=libdl.dladdr; dladdr.argtypes=[ctypes.c_void_p,ctypes.POINTER(Info)]; dladdr.restype=ctypes.c_int
for name in ("libvulkan.so","libEGL.so","libGLESv2.so","libOpenCL.so"):
    try:
        h=ctypes.CDLL(name)
        print("\n",name,"handle",hex(h._handle))
        for sym in ({"libvulkan.so":["vkGetInstanceProcAddr"],"libEGL.so":["eglGetDisplay"],"libGLESv2.so":["glGetString"],"libOpenCL.so":["clGetPlatformIDs"]}[name]):
            try:
                f=getattr(h,sym); i=Info(); ok=dladdr(ctypes.cast(f,ctypes.c_void_p),ctypes.byref(i))
                print(sym, i.fname.decode(errors="replace") if ok and i.fname else "?")
            except Exception as e: print(sym,"MISSING",repr(e))
    except Exception as e: print(name,"LOAD_FAILED",repr(e))
PY
echo
echo "===== 5. Controlled LD_LIBRARY_PATH name resolution tests ====="
for path in /vendor/lib64 /system/vendor/lib64 /system/lib64 "$PREFIX/lib"; do
  echo "--- LD_LIBRARY_PATH=$path ---"
  LD_LIBRARY_PATH="$path" python - <<'PY'
import ctypes, os
libdl=ctypes.CDLL("libdl.so")
class I(ctypes.Structure):
 _fields_=[("f",ctypes.c_char_p),("b",ctypes.c_void_p),("s",ctypes.c_char_p),("a",ctypes.c_void_p)]
d=libdl.dladdr; d.argtypes=[ctypes.c_void_p,ctypes.POINTER(I)]; d.restype=ctypes.c_int
for n,s in (("libOpenCL.so","clGetPlatformIDs"),("libvulkan.so","vkGetInstanceProcAddr")):
 try:
  h=ctypes.CDLL(n); fn=getattr(h,s); i=I(); ok=d(ctypes.cast(fn,ctypes.c_void_p),ctypes.byref(i))
  print(n,"OK",i.f.decode(errors="replace") if ok and i.f else "?")
  if n=="libOpenCL.so":
   count=ctypes.c_uint(); rc=fn(0,None,ctypes.byref(count)); print(" OPENCL_STATUS",rc,"COUNT",count.value)
 except Exception as e: print(n,"FAILED",repr(e))
PY
done
echo
echo "===== 6. Termux Vulkan package ownership ====="
dpkg -S "$PREFIX/lib/libvulkan.so" "$PREFIX/bin/vulkaninfo" 2>&1 || true
echo
echo "===== 7. End ====="
echo "Read-only loader audit. No source/build/system files modified."
echo "REPORT=$REPORT"
} > "$REPORT" 2>&1
cat "$REPORT" | termux-share -a send -c text/plain
