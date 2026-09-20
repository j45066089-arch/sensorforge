#!/usr/bin/env python3
"""HEIC-Exif-Extraktor: findet die Exif-Item-Box ueber iinf/iloc und zieht
den TIFF-Block heraus. Danach MakerNote-Tags auflisten (fuer SensorForge)."""
import struct
import sys

PATH = r"C:\Users\shosh\SensorForgePro\test\real_photo.heic"


def read_box(buf, off):
    size = struct.unpack(">I", buf[off:off+4])[0]
    typ = buf[off+4:off+8].decode("latin-1")
    hdr = 8
    if size == 1:
        size = struct.unpack(">Q", buf[off+8:off+16])[0]
        hdr = 16
    if size == 0:
        size = len(buf) - off
    return typ, hdr, size


def iter_boxes(buf, start, end):
    off = start
    while off + 8 <= end:
        typ, hdr, size = read_box(buf, off)
        if size < hdr or off + size > end:
            return
        yield typ, off + hdr, off + size
        off += size


def find_box(buf, start, end, want):
    for typ, s, e in iter_boxes(buf, start, end):
        if typ == want:
            return s, e
    return None


def main():
    data = open(PATH, "rb").read()

    # meta-Box
    meta_s, meta_e = None, None
    for typ, s, e in iter_boxes(data, 0, len(data)):
        if typ == "meta":
            meta_s, meta_e = s, e
            break
    print("meta:", meta_s, meta_e)

    # meta = FullBox: 4 Byte Version/Flags, dann Kinder
    inner_s = meta_s + 4
    iinf = find_box(data, inner_s, meta_e, "iinf")
    iloc = find_box(data, inner_s, meta_e, "iloc")
    print("iinf:", iinf, "iloc:", iloc)

    # --- iinf: item_infos (FullBox: 4 Bytes version/flags, dann 2B entry_count)
    s, e = iinf
    p = s + 4
    entry_count = struct.unpack(">H", data[p:p+2])[0]
    p += 2
    items = []  # (item_id, item_type)
    for i in range(entry_count):
        _, hdr, size = read_box(data, p)
        body = data[p+hdr:p+size]
        item_id = struct.unpack(">H", body[4:6])[0]
        item_type = body[8:12].decode("latin-1")
        items.append((item_id, item_type))
        p += size
    print("items:", len(items), "Exif:", [i for i in items if i[1] == "Exif"])

    # --- iloc (version 0): item locations ---
    s, e = iloc
    p = s
    ver = struct.unpack(">B", data[p:p+1])[0]  # FULL Box: 1 Byte Version
    p += 4                                     # version + 3 Bytes flags
    offsz = data[p] >> 4
    lensz = data[p] & 0x0F
    baseoffsz = data[p+1] >> 4
    p += 2
    item_count = struct.unpack(">H", data[p:p+2])[0]
    p += 2
    print(f"iloc v{ver}: offsz={offsz} lensz={lensz} baseoffsz={baseoffsz} items={item_count}")

    loc = {}
    for i in range(item_count):
        item_id = struct.unpack(">H", data[p:p+2])[0]
        p += 2
        data_ref = struct.unpack(">H", data[p:p+2])[0]
        p += 2
        if ver >= 1:  # version 1/2: construction_method + data_ref_index
            p += 4
        if baseoffsz:
            p += baseoffsz
        ext_count = struct.unpack(">H", data[p:p+2])[0]
        p += 2
        exts = []
        for _ in range(ext_count):
            eoff = int.from_bytes(data[p:p+offsz], "big")
            p += offsz
            elen = int.from_bytes(data[p:p+lensz], "big")
            p += lensz
            exts.append((eoff, elen))
        loc[item_id] = exts

    # mdat-Offset fuer absolute Positionsberechnung
    mdat_off = None
    for typ, s, e in iter_boxes(data, 0, len(data)):
        if typ == "mdat":
            mdat_off = s
            break
    print("mdat @", mdat_off)

    exif_id = next((i for i, t in items if t == "Exif"), None)
    if exif_id is None or exif_id not in loc:
        print("KEIN Exif-Item gefunden")
        return
    eoff, elen = loc[exif_id][0]
    abs_off = mdat_off + eoff
    payload = data[abs_off:abs_off+elen]
    print(f"Exif-Payload: item={exif_id} off={eoff} len={elen} -> abs {abs_off}")
    print("head:", payload[:16].hex())

    # HEIF-Exif-Item: 4-Byte Big-Endian Offset zum TIFF
    tiff_off = struct.unpack(">I", payload[:4])[0]
    tiff = payload[4+tiff_off:]
    out = r"C:\Users\shosh\SensorForgePro\test\real_exif.tiff"
    with open(out, "wb") as f:
        f.write(tiff)
    print("TIFF:", len(tiff), "bytes ->", out, "| Byteorder:", tiff[:2])


if __name__ == "__main__":
    main()
