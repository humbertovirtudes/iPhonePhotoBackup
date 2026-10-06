#!/usr/bin/env python3
"""iPhone storage helper (USB, via pymobiledevice3). Read-only except
`uninstall` and `wipedata` (both destructive).

Usage:
    iphone_tools.py list                  -> {"apps": [{id,name,type,container,version}]}
    iphone_tools.py size <bundle-id>      -> {"id": .., "bytes": N | null}
    iphone_tools.py uninstall <bundle-id> -> {"id": .., "ok": true}
    iphone_tools.py wipedata <bundle-id>  -> {"id": .., "freed": N, "removed": M}

wipedata vends the app's Data container and deletes everything inside it
(offline maps, caches, documents) while keeping the app installed.
JSON goes to stdout; diagnostics to stderr; nonzero exit on failure.
System apps usually expose no vendable container (size null, wipe fails).
"""
import asyncio
import json
import sys
import traceback

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.house_arrest import HouseArrestService


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


def walk_size(afc, root):
    total = 0
    try:
        walker = afc.walk(root)
    except Exception:
        return None
    try:
        for dirpath, _dirnames, filenames in walker:
            for fn in filenames:
                try:
                    st = afc.stat(dirpath.rstrip("/") + "/" + fn)
                    total += int(getattr(st, "st_size", 0) or 0)
                except Exception:
                    continue
    except Exception:
        return None
    return total


async def cmd_size(bid):
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    raw = await InstallationProxyService(lockdown).get_apps()
    meta = raw.get(bid, {}) if isinstance(raw, dict) else {}
    container = meta.get("Container")
    if not container:
        print(json.dumps({"id": bid, "bytes": None}))
        return
    # App Data containers are only reachable via house_arrest (per-app AFC).
    # This fails for most System apps (no vendable container) -> size null.
    try:
        ha = await HouseArrestService.create(lockdown=lockdown, bundle_id=bid)
    except Exception as e:
        print(json.dumps({"id": bid, "bytes": None, "warning": f"house_arrest: {e}"}))
        return
    print(json.dumps({"id": bid, "bytes": walk_size(ha, "/")}))


async def cmd_uninstall(bid):
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    r = InstallationProxyService(lockdown).uninstall(bid)
    if asyncio.iscoroutine(r):
        await r
    print(json.dumps({"id": bid, "ok": True}))


async def cmd_wipedata(bid):
    """Delete everything inside the app's Data container (app stays installed)."""
    lockdown = create_using_usbmux()
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    ha = await HouseArrestService.create(lockdown=lockdown, bundle_id=bid)
    before = walk_size(ha, "/") or 0
    removed = 0
    try:
        top = ha.listdir("/")
    except Exception as e:
        print(json.dumps({"id": bid, "freed": 0, "removed": 0, "warning": f"listdir: {e}"}))
        return
    if isinstance(top, dict):
        top = list(top.keys())
    for name in top:
        try:
            r = ha.rm("/" + str(name))
            if asyncio.iscoroutine(r):
                await r
            removed += 1
        except Exception:
            continue
    after = walk_size(ha, "/") or 0
    print(json.dumps({"id": bid, "freed": max(0, before - after), "removed": removed}))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("list", "size", "uninstall", "wipedata"):
        print("usage: iphone_tools.py [list|size <bid>|uninstall <bid>|wipedata <bid>]",
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
        elif argv[1] == "wipedata":
            if len(argv) < 3:
                print("usage: iphone_tools.py wipedata <bundle-id>", file=sys.stderr)
                return 2
            asyncio.run(cmd_wipedata(argv[2]))
        else:
            if len(argv) < 3:
                print("usage: iphone_tools.py uninstall <bundle-id>", file=sys.stderr)
                return 2
            asyncio.run(cmd_uninstall(argv[2]))
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
