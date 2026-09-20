#!/usr/bin/env python3
"""Neuestes Foto vom AFC (/DCIM) ziehen — fuer den MakerNote-Abgleich."""
import asyncio
import os
import sys

import pymobiledevice3.lockdown as lockdown_mod
from pymobiledevice3.services.afc import AfcService

OUT_DIR = r"C:\Users\shosh\SensorForgePro\test"


async def main():
    ld = await lockdown_mod.create_using_usbmux()
    afc = AfcService(lockdown=ld)

    async def listdir_r(path, depth=0, out=None):
        if out is None:
            out = []
        if depth > 4:
            return out
        for name in await afc.listdir(path):
            p = path.rstrip("/") + "/" + name
            try:
                info = await afc.stat(p)
            except Exception:
                continue
            if info.get("st_ifmt") == "S_IFDIR":
                await listdir_r(p, depth + 1, out)
            else:
                if name.lower().endswith((".jpg", ".jpeg", ".heic", ".png")):
                    mt = info.get("st_mtime", 0)
                    try:
                        mt_ts = mt.timestamp()
                    except AttributeError:
                        mt_ts = float(mt or 0)
                    out.append((p, mt_ts, int(info.get("st_size", 0))))
        return out

    files = await listdir_r("/DCIM")
    files.sort(key=lambda x: -x[1])
    print("fotos:", len(files))
    if not files:
        print("keine Fotos gefunden")
        return
    newest = files[0]
    print("neuestes:", newest)
    data = await afc.get_file_contents(newest[0])
    ext = os.path.splitext(newest[0])[1].lower()
    out = os.path.join(OUT_DIR, "real_photo" + ext)
    with open(out, "wb") as f:
        f.write(data)
    print("gespeichert:", out, len(data), "bytes")


asyncio.run(main())
