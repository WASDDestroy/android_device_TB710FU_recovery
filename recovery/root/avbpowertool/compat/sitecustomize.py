"""Runtime shim so the upstream checkout can stay 100% pristine.

avbtool.py prefers the in-tree pure-Python FEC encoder:

    try:
        from avbpowertool.vendor.fec_encoder import generate_fec_data as _py_fec
        return _py_fec(image_filename, num_roots)
    except ImportError:
        pass
    ... subprocess: fec --encode ...

That module imports numpy lazily, so the *import* always succeeds and, without
numpy installed, it raises RuntimeError -- which avbtool does NOT catch, so it
never falls back to the external `fec` binary.

Instead of deleting/patching that file, this meta-path hook makes the import
raise ModuleNotFoundError (an ImportError subclass) so avbtool takes its own
external-tool path.  No file inside the avbpowertool checkout is touched.

Disable with AVBPT_NO_FEC_BLOCK=1 (only useful if numpy is actually installed).
"""
from __future__ import annotations

import os
import sys

if os.environ.get("AVBPT_NO_FEC_BLOCK") != "1":
    try:
        from importlib.abc import MetaPathFinder

        class _BlockFecEncoder(MetaPathFinder):
            _blocked = frozenset({"avbpowertool.vendor.fec_encoder"})

            def find_spec(self, fullname, path=None, target=None):  # noqa: ANN001
                if fullname in self._blocked:
                    raise ModuleNotFoundError(
                        f"{fullname} disabled by avbpt (using external 'fec')"
                    )
                return None

        sys.meta_path.insert(0, _BlockFecEncoder())
    except Exception as exc:  # pragma: no cover - must never break start-up
        print(f"avbpt: FEC encoder shim failed: {exc}", file=sys.stderr)
