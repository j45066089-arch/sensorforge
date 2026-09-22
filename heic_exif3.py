#!/usr/bin/env python3
"""Direktparsen des HEIC-EXIF: Scan nach 'Exif\\0\\0' + TIFF (II/MM).

Robust gegen iloc-Besonderheiten, weil der Marker 1:1 den TIFF-Anfang zeigt.
"""
import json
import struct
import sys

PATH = r"C:\Users\shosh\SensorForgePro\test\testshot2.heic"

def parse(path):
    data = open(path, "rb").read()

    # alle Vorkommen von Exif\0\0 suchen, TIFF-magic direkt danach pruefen
    tiff = None
    pos = 0
    while True:
        i = data.find(b"Exif\x00\x00", pos)
        if i < 0:
            break
        head = data[i+6:i+6+4]
        if head[:2] in (b"II", b"MM"):
            tiff = data[i+6:i+6+800000]  # grosszuegig
            break
        pos = i + 1
    if tiff is None:
        return {"_err": "kein Exif-TIFF gefunden"}

    endian = "<" if tiff[:2] == b"II" else ">"
    magic = struct.unpack(endian + "H", tiff[2:4])[0]
    if magic != 42:
        return {"_err": "TIFF-magic kaputt"}
    ifd0_off = struct.unpack(endian + "I", tiff[4:8])[0]

    def u16(b, o):
        return struct.unpack(endian + "H", b[o:o+2])[0]

    def u32(b, o):
        return struct.unpack(endian + "I", b[o:o+4])[0]

    # Spezifische Tags: FNumber, Exposure, ISO, Lens, plus breiter Scan ALLER Tags
    TAG_NAMES = {
        0x010F: "Make", 0x0110: "Model", 0x0112: "Orientation",
        0x829A: "ExposureTime", 0x829D: "FNumber", 0x8827: "ISOSpeedRatings",
        0x9003: "DateTimeOriginal", 0x9201: "ShutterSpeedValue",
        0x9202: "ApertureValue", 0x920A: "FocalLength", 0xA402: "ExposureMode",
        0xA433: "LensMake", 0xA434: "LensModel", 0xA435: "LensSerialNumber",
        0x9211: "ImageNumber",
    }

    def parse_value(block, ent, typ, cnt):
        vp = ent + 8
        if typ == 2:
            if cnt <= 4:
                return block[vp:vp+cnt].rstrip(b"\x00").decode("latin-1", "replace")
            return block[u32(block, vp):u32(block, vp)+cnt].rstrip(b"\x00").decode("latin-1", "replace")
        if typ == 3:
            if cnt <= 2:
                return [u16(block, vp + i*2) for i in range(cnt)]
            off = u32(block, vp)
            return [u16(block, off + i*2) for i in range(cnt)]
        if typ == 4:
            if cnt == 1:
                return u32(block, vp)
            off = u32(block, vp)
            return [u32(block, off + i*4) for i in range(cnt)]
        if typ in (5, 10):
            off = u32(block, vp)
            vals = []
            for i in range(cnt):
                num = u32(block, off + i*8)
                den = u32(block, off + i*8 + 4)
                vals.append(num / den if den else 0.0)
            return vals[0] if cnt == 1 else vals
        if typ == 7:
            if cnt <= 4:
                return block[vp:vp+cnt].hex()
            off = u32(block, vp)
            return block[off:off+cnt].hex()
        return "typ%d" % typ

    def walk_ifd(block, offset, depth=0):
        out = {}
        if offset + 2 > len(block) or depth > 3:
            return out
        n = u16(block, offset)
        for i in range(n):
            ent = offset + 2 + i * 12
            if ent + 12 > len(block):
                break
            tag = u16(block, ent)
            typ = u16(block, ent + 2)
            cnt = u32(block, ent + 4)
            v = parse_value(block, ent, typ, cnt)
            if tag == 0x8769:  # ExifIFD-Pointer
                out["ExifIFD"] = walk_ifd(block, u32(block, ent + 8), depth + 1)
            else:
                name = TAG_NAMES.get(tag, "tag_0x%04X" % tag)
                out[name] = v
        return out

    return walk_ifd(tiff, ifd0_off)

if __name__ == "__main__":
    r = parse(PATH)
    print(json.dumps(r, indent=2, ensure_ascii=False))
