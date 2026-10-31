#!/usr/bin/env python3
"""Preflight checks and configuration values for the oneroot locked flow.

Input is the JSON produced by::

    avbpt image inspect boot dtbo init_boot pvmfw recovery \
        vbmeta vbmeta_system vendor_boot --json

Usage::

    oneroot_preflight.py INSPECT_JSON strict|warn [ENV_OUT]

The script validates that the eight partitions still form a bootable AVB
chain and writes shell-sourceable values to ENV_OUT (default: stdout).
It also derives the per-firmware signing targets:

  RECOVERY_RI   recovery rollback index, at least 1
  VS_ALG        SHA256_RSA2048 / SHA256_RSA4096 for vbmeta_system
  VS_KEY        matching testkey id
  ZUXOS         x.y.z.w parsed from any *.fingerprint AVB prop
  ABL_NEEDED    yes / no / unknown, based on ZUXOS >= 1.5.04.445

This script only uses the Python standard library; the recovery payload
ships Python 3.12.
"""

import json
import re
import sys

IMAGES = [
    "boot",
    "dtbo",
    "init_boot",
    "pvmfw",
    "recovery",
    "vbmeta",
    "vbmeta_system",
    "vendor_boot",
]

# Partitions that must carry a real signature (not the NONE hash footer).
SIGNED = ["boot", "recovery", "vbmeta_system", "vbmeta"]

# Partitions that are chained from the top-level vbmeta.
CHAIN_LOCATIONS = {
    "boot": "3",
    "recovery": "1",
    "vbmeta_system": "2",
}

# Hash/hashtree descriptors are embedded in the image itself.
HASH_PARTITIONS = ["boot", "dtbo", "init_boot", "pvmfw", "recovery", "vendor_boot"]

ZUXOS_RE = re.compile(r"ZUXOS_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)")
ABL_MIN = (1, 5, 4, 445)


def _text(value):
    if value is None:
        return ""
    return str(value).strip()


def _sha1(value):
    return _text(value).lower()


def _props_to_pairs(props):
    """AVB props are serialized either as [key, value] pairs or as objects.

    The CLI's ``--json`` output uses ``{"key": ..., "value": ...}``; the
    saved profile uses ``[key, value]``.  Accept both.
    """
    pairs = []
    if isinstance(props, dict):
        for key, value in props.items():
            pairs.append((_text(key), _text(value)))
        return pairs
    for item in props or []:
        if isinstance(item, dict):
            pairs.append((_text(item.get("key")), _text(item.get("value"))))
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            pairs.append((_text(item[0]), _text(item[1])))
    return pairs


def parse_zuxos(images):
    """Return x.y.z.w from the first *fingerprint* prop that carries ZUXOS."""
    order = [
        "boot",
        "vbmeta",
        "init_boot",
        "vendor_boot",
        "recovery",
        "dtbo",
        "pvmfw",
        "vbmeta_system",
    ]
    for name in order:
        for key, value in _props_to_pairs(images.get(name, {}).get("props")):
            if "fingerprint" not in key.lower():
                continue
            match = ZUXOS_RE.search(value)
            if match:
                return match.group(1)
    return ""


def version_tuple(text):
    try:
        return tuple(int(part) for part in text.split("."))
    except (TypeError, ValueError):
        return None


def derive_targets(images):
    recovery = images.get("recovery", {})
    try:
        recovery_ri = int(recovery.get("rollback_index") or 0)
    except (TypeError, ValueError):
        recovery_ri = 0
    recovery_ri = max(recovery_ri, 1)

    vs_alg = _text(images.get("vbmeta_system", {}).get("algorithm")).upper()
    if vs_alg not in ("SHA256_RSA2048", "SHA256_RSA4096"):
        vs_alg = "SHA256_RSA2048"
    vs_key = "testkey_rsa2048" if vs_alg.endswith("2048") else "testkey_rsa4096"

    zuxos = parse_zuxos(images)
    parsed = version_tuple(zuxos) if zuxos else None
    if parsed is None:
        abl_needed = "unknown"
    elif parsed >= ABL_MIN:
        abl_needed = "yes"
    else:
        abl_needed = "no"

    return recovery_ri, vs_alg, vs_key, zuxos, abl_needed


def validate(images, issues):
    for name in IMAGES:
        if name not in images:
            issues.append("missing inspect entry for %s" % name)
            continue
        if images[name].get("descriptor") is None:
            issues.append("%s has no AVB structure" % name)

    for name in SIGNED:
        algorithm = _text(images.get(name, {}).get("algorithm")).upper()
        if algorithm == "NONE":
            issues.append("%s is not signed (algorithm NONE)" % name)

    vbmeta = images.get("vbmeta", {})
    chains = vbmeta.get("chain_partitions") or []
    chain_map = {}
    for chain in chains:
        if not isinstance(chain, dict):
            continue
        part = _text(chain.get("partition_name"))
        if part:
            chain_map[part] = chain

    if set(chain_map) != set(CHAIN_LOCATIONS):
        issues.append(
            "vbmeta chains are %s, expected %s"
            % (sorted(chain_map), sorted(CHAIN_LOCATIONS))
        )

    for name, location in CHAIN_LOCATIONS.items():
        chain = chain_map.get(name)
        if chain is None:
            continue
        actual_location = _text(chain.get("rollback_index_location"))
        if actual_location != location:
            issues.append(
                "chain %s uses location %s, expected %s"
                % (name, actual_location or "<empty>", location)
            )
        chain_sha = _sha1(chain.get("public_key_sha1"))
        image_sha = _sha1(images.get(name, {}).get("public_key_sha1"))
        if not chain_sha or chain_sha != image_sha:
            issues.append(
                "chain %s public key does not match the partition (chain=%s image=%s)"
                % (name, chain_sha or "<empty>", image_sha or "<empty>")
            )

    for name in HASH_PARTITIONS:
        partition_name = _text(images.get(name, {}).get("partition_name"))
        if partition_name != name:
            issues.append(
                "%s footer names partition %s" % (name, partition_name or "<empty>")
            )


def write_env(path, recovery_ri, vs_alg, vs_key, zuxos, abl_needed):
    lines = [
        "RECOVERY_RI=%d" % recovery_ri,
        "VS_ALG=%s" % vs_alg,
        "VS_KEY=%s" % vs_key,
        "ZUXOS=%s" % zuxos,
        "ABL_NEEDED=%s" % abl_needed,
    ]
    payload = "\n".join(lines) + "\n"
    if path in ("", "-"):
        sys.stdout.write(payload)
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(payload)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(
            "usage: oneroot_preflight.py INSPECT_JSON strict|warn [ENV_OUT]\n"
        )
        return 2

    inspect_path = argv[1]
    mode = argv[2]
    env_path = argv[3] if len(argv) > 3 else "-"
    if mode not in ("strict", "warn"):
        sys.stderr.write("mode must be strict or warn\n")
        return 2

    try:
        with open(inspect_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("cannot read inspect JSON: %s\n" % exc)
        return 1

    images = {}
    for entry in payload.get("images") or []:
        if isinstance(entry, dict):
            name = _text(entry.get("image_name"))
            if name:
                images[name] = entry

    recovery_ri, vs_alg, vs_key, zuxos, abl_needed = derive_targets(images)
    write_env(env_path, recovery_ri, vs_alg, vs_key, zuxos, abl_needed)

    issues = []
    validate(images, issues)

    if issues and mode == "strict":
        for issue in issues:
            print("[FAIL] %s" % issue)
        print("[ERROR] preflight rejected the current partition set")
        return 1

    for issue in issues:
        print("[WARN] %s" % issue)
    print(
        "[OK] preflight: ri=%d vs_alg=%s zuxos=%s abl=%s (%d warning(s))"
        % (recovery_ri, vs_alg, zuxos or "?", abl_needed, len(issues))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
