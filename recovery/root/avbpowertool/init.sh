#!/system/bin/sh
# AVBPowerTool2 -- self check / first-run initialisation.
# Safe to run any time; only verifies the payload and creates/repairs the
# runtime workspace (default: /tmp, the RAM disk).  The payload is relocatable.
#
#   init.sh                 # check + repair (maintenance use), workspace in /tmp
#   init.sh --data          # same, workspace in /data
#   init.sh --workspace DIR
#   init.sh -q              # quiet: no output, no import test, and NO repair --
#                           # exit code only (used by avbpt on every start)
#   init.sh -q --strict     # quiet but still run the import test
#   init.sh --fix           # force mode repair even in quiet mode
#   init.sh --no-fix        # never chmod, only report
#
# Mode repair is deliberately NOT part of the normal start-up path: the
# packaging (zip/tar, install-adb.sh, device-tree copy) is responsible for
# correct 0755 bits, and `avbpt` only verifies them.
#
_self=$0
if command -v readlink >/dev/null 2>&1; then
    _r=$(readlink -f "$0" 2>/dev/null) && [ -n "$_r" ] && _self=$_r
fi
_here=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
ROOT=${AVBPT_ROOT:-${_here:-/avbpowertool}}

WS_TMP=/tmp/avbpowertool2_workspace
WS_DATA=/data/avbpowertool2_workspace
WS=${AVBPT_WORKSPACE:-$WS_TMP}
QUIET=0
STRICT=0
FIX=""          # "" = auto: repair only in verbose (maintenance) mode
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1; shift ;;
        --strict) STRICT=1; shift ;;
        --fix) FIX=1; shift ;;
        --no-fix) FIX=0; shift ;;
        --workspace) shift; [ $# -gt 0 ] && { WS=$1; shift; } ;;
        --workspace=*) WS=${1#*=}; shift ;;
        --data) WS=$WS_DATA; shift ;;
        --tmp|--ram) WS=$WS_TMP; shift ;;
        *) shift ;;
    esac
done
[ -z "$FIX" ] && FIX=$((1 - QUIET))
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

case "$WS" in
    twrp|auto)
        if [ -d /sdcard ] && [ -w /sdcard ]; then
            f=$AVBPT_TWRP_FOLDER
            [ -n "$f" ] || f=$(getprop ro.twrp.folder 2>/dev/null)
            if [ -z "$f" ]; then
                for d in /mnt/vendor/persist/* /sdcard/* /data/media/0/*; do
                    [ -d "$d" ] || continue
                    if [ -e "$d/.twrp_settings" ] || [ -e "$d/.twrps" ]; then
                        f=$(basename "$d"); break
                    fi
                done
            fi
            [ -n "$f" ] || f=$(sed -n "s#.*Backup folder set to '/data/media/0/\([^/]*\)/BACKUPS.*#\1#p" /tmp/recovery.log 2>/dev/null | tail -1)
            WS="/sdcard/${f:-TWRP}/avbpowertool"
        else
            WS=$WS_TMP
        fi
        ;;
esac
case "$WS" in
    /tmp/*) mkdir -p "$WS" 2>/dev/null || WS=$WS_DATA ;;
esac
fail=0

say "== payload: $ROOT"
for f in avbpt app/avbtool.py app/avbpowertool/__init__.py \
         py/python py/libpython3.12.so.1.0 \
         stdlib/python312.zip pylib/unicodedata.cpython-312.so \
         bin/fec terminfo/t/twrp tools/ttyprobe.py; do
    if [ -e "$ROOT/$f" ]; then say "  ok      $f"; else say "  MISSING $f"; fail=1; fi
done

# FEC substitution: either the pristine file is present and blocked at runtime
# by compat/sitecustomize.py, or it was renamed to .disabled.
V=$ROOT/app/avbpowertool/vendor
if [ -e "$V/fec_encoder.py" ]; then
    if [ -e "$ROOT/compat/sitecustomize.py" ]; then
        say "  ok      compat/sitecustomize.py (blocks in-tree FEC)"
    else
        say "  MISSING compat/sitecustomize.py -> FEC would need numpy"
        fail=1
    fi
elif [ -e "$V/fec_encoder.py.disabled" ]; then
    say "  ok      vendor/fec_encoder.py.disabled (rename variant)"
else
    say "  MISSING vendor/fec_encoder.py(.disabled)"
    fail=1
fi

# --- executable bits -------------------------------------------------------
# Packaging is responsible for these (zip/tar store modes, install-adb.sh
# chmods, a device-tree copy keeps what git recorded).  Here we only verify,
# and repair when explicitly asked (verbose maintenance run, or --fix).
needs_fix=0
for f in avbpt init.sh termcheck keytest bin/fec py/python; do
    p=$ROOT/$f
    [ -e "$p" ] || continue
    if [ -x "$p" ]; then
        continue
    fi
    if [ "$FIX" -eq 1 ] && chmod 755 "$p" 2>/dev/null && [ -x "$p" ]; then
        say "  fixed   mode 0755 $f"
    else
        say "  BAD     mode 0755 required: $f"
        needs_fix=1
    fi
done
if [ "$needs_fix" -eq 1 ]; then
    say "  -> fix with: sh $ROOT/init.sh --fix"
    fail=1
fi

say "== workspace: $WS"
case "$WS" in
    /tmp/*) say "  note    RAM disk -- contents are lost on reboot" ;;
esac
if ! mkdir -p "$WS/Images" "$WS/profiles" "$WS/plugins" "$WS/Logs" \
                "$WS/.avbpowertool-staging" "$WS/.tmp" 2>/dev/null; then
    say "  cannot create workspace"; fail=1
fi

# avbtool.py must sit in the workspace root (WorkspacePaths.avbtool_script).
# Refresh it when missing or dangling (e.g. after the payload was relocated).
if [ "$fail" -eq 0 ] && [ ! -e "$WS/avbtool.py" ]; then
    rm -f "$WS/avbtool.py" 2>/dev/null
    ln -s "$ROOT/app/avbtool.py" "$WS/avbtool.py" 2>/dev/null || \
        cp "$ROOT/app/avbtool.py" "$WS/avbtool.py"
fi

# The import test spawns a second interpreter (~200 ms) -- skip it in quiet
# mode, where only exit status matters.  --strict forces it anyway.
if [ "$fail" -eq 0 ] && { [ "$QUIET" -eq 0 ] || [ "$STRICT" -eq 1 ]; }; then
    if PYTHONHOME="$ROOT/py" LD_LIBRARY_PATH="$ROOT/py:/system/lib64" \
       PYTHONPATH="$ROOT/compat:$ROOT/app:$ROOT/stdlib/python312.zip:$ROOT/pylib" \
       PYTHONDONTWRITEBYTECODE=1 \
       "$ROOT/py/python" -c "import sys, importlib, unicodedata, curses, json, argparse, hashlib, subprocess; print('  python', sys.version.split()[0], 'imports OK')"; then
        :
    else
        say "  python import test FAILED"
        fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    say "== ready:  $ROOT/avbpt        (or: sh $ROOT/avbpt about)"
else
    say "== NOT ready"
fi
exit "$fail"
