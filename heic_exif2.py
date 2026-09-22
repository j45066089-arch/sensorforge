#!/usr/bin/env python3
"""Robuster HEIC-EXIF-Extraktor (ISO-BMFF).

Findet die Exif-Item-Box im meta, baut aus iinf/iloc den Item-Inhalt
zusammen und parst das TIFF. Nutzt ausschliesslich stdlib.
"""
import struct
import sys

PATH = r"C:\Users\shosh\SensorForgePro\test\testshot.heic"


def parse_heic_exif(path):
    data = open(path, "rb").read()

    def box_at(buf, off):
        if off + 8 > len(buf):
            return None
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
            b = box_at(buf, off)
            if b is None:
                return
            typ, hdr, size = b
            if size < hdr or off + size > end:
                return
            yield typ, off + hdr, off + size
            off += size

    # meta-Box + mdat finden
    meta = None
    mdat = None
    for typ, s, e in iter_boxes(data, 0, len(data)):
        if typ == "meta" and meta is None:
            meta = (s, e)
        elif typ == "mdat" and mdat is None:
            mdat = (s, e)
    if meta is None:
        return {}
    # meta = FullBox -> Kinder ab s+4
    m_s, m_e = meta
    iinf = iloc = None
    for typ, s, e in iter_boxes(data, m_s + 4, m_e):
        if typ == "iinf":
            iinf = (s, e)
        elif typ == "iloc":
            iloc = (s, e)
    if iinf is None or iloc is None:
        return {}

    # iinf: FullBox (4) + 2B count + infe-Child-Boxen
    s, e = iinf
    p = s + 4
    count = struct.unpack(">H", data[p:p+2])[0]
    p += 2
    items = []
    for _ in range(count):
        b = box_at(data, p)
        if b is None:
            break
        _, hdr, size = b
        body = data[p+hdr:p+size]
        # infe v2: version+flags(4), item_ID(2), protection(2), item_type(4), name(0-terminated)
        if len(body) >= 12:
            iid = struct.unpack(">H", body[4:6])[0]
            itype = body[8:12].decode("latin-1").rstrip("\x00")
            items.append((iid, itype))
        p += size

    # iloc: FullBox (version 0/1/2)
    s, e = iloc
    p = s
    ver = data[p]
    p += 4
    offsz = data[p] >> 4
    lensz = data[p] & 0x0F
    baseoffsz = data[p+1] >> 4
    idxsz = 0
    if ver == 1 or ver == 2:
        idxsz = data[p+1] & 0x0F
    p += 2
    if ver < 2:
        item_count = struct.unpack(">H", data[p:p+2])[0]
        p += 2
    else:
        item_count = struct.unpack(">I", data[p:p+4])[0]
        p += 4
    loc = {}
    for _ in range(item_count):
        if ver < 2:
            iid = struct.unpack(">H", data[p:p+2])[0]
            p += 2
        else:
            iid = struct.unpack(">I", data[p:p+4])[0]
            p += 4
        if ver >= 1:
            p += 2  # construction_method
        p += 2  # data_ref_index
        if baseoffsz:
            p += baseoffsz
        ec = struct.unpack(">H", data[p:p+2])[0]
        p += 2
        exts = []
        for _ in range(ec):
            if idxsz:
                p += idxsz
            eoff = int.from_bytes(data[p:p+offsz], "big") + baseoffsz
            p += offsz
            elen = int.from_bytes(data[p:p+lensz], "big")
            p += lensz
            exts.append((eoff, elen))
        loc[iid] = exts

    exif_item = next((i for i, t in items if t == "Exif"), None)
    if exif_item is None or exif_item not in loc:
        return {"_err": "kein Exif-Item"}
    eoff, elen = loc[exif_item][0]
    base = mdat[0] if mdat else 0
    payload = data[base+eoff:base+eoff+elen]
    # HEIF-Exif-Item: 4-Byte Offset zum TIFF-Header
    try:
        t_off = struct.unpack(">I", payload[:4])[0]
    except struct.error:
        return {"_err": "Exif-Payload zu klein"}
    tiff = payload[4+t_off:]

    # TIFF (IFD0 -> ExifIFD) parsen
    if len(tiff) < 10:
        return {"_err": "TIFF zu klein"}
    endian = "<" if tiff[:2] == b"II" else ">"
    magic = struct.unpack(endian + "H", tiff[2:4])[0]
    if magic != 42:
        return {"_err": "kein TIFF"}

    def u16(b, o):
        return struct.unpack(endian + "H", b[o:o+2])[0]
    def u32(b, o):
        return struct.unpack(endian + "I", b[o:o+4])[0]

    TAG_NAMES = {
        0x829A: "ExposureTime", 0x829D: "FNumber", 0x8827: "ISOSpeedRatings",
        0x9209: "Flash", 0xA434: "LensModel", 0x9003: "DateTimeOriginal",
        0x9202: "ApertureValue", 0xA405: "FocalLenIn35mm", 0xFDE9: "FocalLen35mmEq",
        0x920A: "FocalLength",
    }

    def walk_ifd(block, offset):
        out = {}
        if offset + 2 > len(block):
            return out
        n = u16(block, offset)
        for i in range(n):
            ent = offset + 2 + i * 12
            if ent + 12 > len(block):
                break
            tag = u16(block, ent)
            typ = u16(block, ent + 2)
            cnt = u32(block, ent + 4)
            size = 0
            if typ == 1 or typ == 2 or typ == 7:
                size = cnt
            elif typ == 3:
                size = cnt * 2
            elif typ in (4, 9):
                size = cnt * 4
            elif typ in (5, 10):
                size = cnt * 8
            vp = ent + 8
            raw = block[vp:vp+size] if size <= 4 else None
            if raw is None:
                vo = u32(block, vp)
                raw = block[vo:vo+size]
            if tag in TAG_NAMES and cnt:
                name = TAG_NAMES[tag]
                if typ == 3:
                    out[name] = u16(raw, 0)
                elif typ == 4:
                    out[name] = u32(raw, 0)
                elif typ in (5, 10):
                    num = u32(raw, 0); den = u32(raw, 4)
                    out[name] = num / den if den else 0.0
                elif typ == 2:
                    out[name] = raw.rstrip(b"\x00").decode("latin-1", "replace")
                elif typ == 1:
                    out[name] = raw.hex()
            if tag == 0x8769:  # ExifIFD
                out["_exif_ifd_off"] = u32(block, vp)
        return out

    ifd0 = walk_ifd(tiff, u32(tiff, 4))
    if "_exif_ifd_off" in ifd0:
        exif_ifd = walk_ifd(tiff, ifd0["_exif_ifd_off"])
        ifd0["ExifIFD"] = exif_ifd
        ifd0.update(exif_ifd)
    return ifd0

if __name__ == "__main__":
    import json
    r = parse_heic_exif(PATH)
    print(json.dumps(r, indent=2, ensure_ascii=False))
