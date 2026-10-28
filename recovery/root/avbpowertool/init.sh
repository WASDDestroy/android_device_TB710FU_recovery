#!/system/bin/sh
# AVBPowerTool2 -- self check / first-run initialisation.
# Safe to run any time; only verifies the payload and creates the runtime
# workspace under /data.  The payload is relocatable (see avbpt).
_self=$0
if command -v readlink >/dev/null 2>&1; then
    _r=$(readlink -f "$0" 2>/dev/null) && [ -n "$_r" ] && _self=$_r
fi
_here=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
ROOT=${AVBPT_ROOT:-${_here:-/avbpowertool}}
WS=${AVBPT_WORKSPACE:-/data/avbpowertool2_workspace}
fail=0

echo "== payload: $ROOT"
for f in avbpt app/avbtool.py app/avbpowertool/__init__.py \
         py/python py/libpython3.12.so.1.0 \
         stdlib/python312.zip pylib/unicodedata.cpython-312.so \
         bin/fec terminfo/t/twrp tools/ttyprobe.py; do
    if [ -e "$ROOT/$f" ]; then echo "  ok      $f"; else echo "  MISSING $f"; fail=1; fi
done

# files copied from Windows / zip archives often lose the executable bit
for f in avbpt init.sh bin/fec py/python; do
    [ -e "$ROOT/$f" ] && chmod 755 "$ROOT/$f" 2>/dev/null
done

echo "== workspace: $WS"
if ! mkdir -p "$WS/Images" "$WS/profiles" "$WS/plugins" "$WS/Logs" \
                "$WS/.avbpowertool-staging" "$WS/.tmp" 2>/dev/null; then
    echo "  cannot create workspace"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    PYTHONHOME="$ROOT/py" LD_LIBRARY_PATH="$ROOT/py:/system/lib64" \
    PYTHONPATH="$ROOT/app:$ROOT/stdlib/python312.zip:$ROOT/pylib" \
    "$ROOT/py/python" -c "import sys, importlib, unicodedata, curses, json, argparse, hashlib, subprocess; print('  python', sys.version.split()[0], 'imports OK')" || fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "== ready:  $ROOT/avbpt        (or: sh $ROOT/avbpt about)"
else
    echo "== NOT ready"
fi
exit "$fail"
