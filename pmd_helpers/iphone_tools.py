#!/usr/bin/env python3
"""iPhone storage helper (USB, via pymobiledevice3). Read-only except
`uninstall` (destructive).

Usage:
    iphone_tools.py list                  -> {"apps": [{id,name,type,container,version}]}
    iphone_tools.py size <bundle-id>      -> {"id": .., "bytes": N | null,
                                              "parts": [{path,size}]}
    iphone_tools.py sizes <bid>...        -> {"sizes": {bid: {"bytes": N|null,
                                              "parts": [...]}}} (one Lookup)
    iphone_tools.py uninstall <bundle-id> -> {"id": .., "ok": true}

Sizes come from installation_proxy disk-usage keys (no container access
needed, works while locked). JSON to stdout; nonzero exit on failure.
"""
import asyncio
import json
import sys
import traceback

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService


async def get_apps():
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    svc = InstallationProxyService(lockdown)
    raw = svc.get_apps()
    if asyncio.iscoroutine(raw):
        raw = await raw
    return lockdown, raw


def cmd_list():
    _, raw = asyncio.run(get_apps())
    items = raw.items() if isinstance(raw, dict) else [(a.get("CFBundleIdentifier", "?"), a) for a in raw]
    apps = []
    for bid, meta in items:
        meta = meta or {}
        apps.append({
            "id": bid,
            "name": meta.get("CFBundleDisplayName") or meta.get("CFBundleName") or bid,
            "type": meta.get("ApplicationType", "?"),
            "container": meta.get("Container"),
            "version": meta.get("CFBundleShortVersionString", ""),
        })
    apps.sort(key=lambda a: (a["type"] != "User", a["name"].lower()))
    print(json.dumps({"apps": apps}))


async def cmd_size(bid):
    # Per-app sizes straight from installation_proxy — no container access
    # needed (house_arrest refuses most apps), works even while locked.
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    raw = await InstallationProxyService(lockdown).lookup(
        {"BundleIDs": [bid], "ReturnAttributes": ["StaticDiskUsage", "DynamicDiskUsage"]})
    meta = raw.get(bid, {}) if isinstance(raw, dict) else {}
    entry = _sized_entry(meta)
    entry["id"] = bid
    print(json.dumps(entry))


def _sized_entry(meta):
    def num(v):
        return int(v) if isinstance(v, (int, float)) else None
    static = num(meta.get("StaticDiskUsage"))
    dynamic = num(meta.get("DynamicDiskUsage"))
    parts = []
    if static is not None:
        parts.append({"path": "App", "bytes": static})
    if dynamic is not None:
        parts.append({"path": "Data", "bytes": dynamic})
    total = (static or 0) + (dynamic or 0)
    return {
        "bytes": total if (static is not None or dynamic is not None) else None,
        "parts": parts,
    }


async def cmd_sizes(bids):
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    raw = await InstallationProxyService(lockdown).lookup(
        {"BundleIDs": bids, "ReturnAttributes": ["StaticDiskUsage", "DynamicDiskUsage"]})
    out = {}
    for bid in bids:
        meta = raw.get(bid, {}) if isinstance(raw, dict) else {}
        out[bid] = _sized_entry(meta)
    print(json.dumps({"sizes": out}))


async def cmd_uninstall(bid):
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    r = InstallationProxyService(lockdown).uninstall(bid)
    if asyncio.iscoroutine(r):
        await r
    print(json.dumps({"id": bid, "ok": True}))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("list", "size", "sizes", "uninstall"):
        print("usage: iphone_tools.py [list|size <bid>|sizes <bid>...|uninstall <bid>]",
              file=sys.stderr)
        return 2
    try:
        if argv[1] == "list":
            cmd_list()
        elif argv[1] == "size":
            if len(argv) < 3:
                print("usage: iphone_tools.py size <bundle-id>", file=sys.stderr)
                return 2
            asyncio.run(cmd_size(argv[2]))
        elif argv[1] == "sizes":
            if len(argv) < 3:
                print("usage: iphone_tools.py sizes <bid>...", file=sys.stderr)
                return 2
            asyncio.run(cmd_sizes(argv[2:]))
        else:
            if len(argv) < 3:
                print("usage: iphone_tools.py uninstall <bundle-id>", file=sys.stderr)
                return 2
            asyncio.run(cmd_uninstall(argv[2]))
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        msg = f"{type(e).__name__}: {e}"
        if "LookupFailed" in msg:
            msg += " (usually: iPhone is locked — unlock it and retry)"
        print(json.dumps({"error": msg}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
