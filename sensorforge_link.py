#!/usr/bin/env python3
"""
SensorForge Link - PC-seitiges Fuetterungstool fr SensorForge Pro.

Analysiert ein Bild oder Video (EXIF bzw. mittlere Luminanz) und schiebt
die berechneten Sensorwerte als Textkommandos an den Tweak-Status-Port:

    iso=<n> exposure=<s> fnumber=<f> lux=<lx> lens=<name>

Nutzt denselben Kanal, den der Tweak versteht (ISO/Exposure/FNumber/Lux
werden live uebernommen, Lux korreliert dann mit ISO*Exposure).

Anforderungen (Host): python3 + (fr Video) ffmpeg im PATH.

Beispiele:
    python sensorforge_link.py --image portrait.jpg
    python sensorforge_link.py --video clip.mp4 --framecap 10
    python sensorforge_link.py --image pic.heic --port 8797 --host 127.0.0.1

Video->ISO-Schätzung (NikeCam-Muster):
    lux  <- mittlere Y-Luma eines Frames
    iso  <- clamp(120000/(lux+1), 50, 3200)
"""
import argparse
import json
import re
import socket
import subprocess
import sys

DEFAULT_PORT = 8797
DEFAULT_HOST = "127.0.0.1"

# ---------------------------------------------------------------------------
# EXIF-Leser (Bilder). Ohne externe Dependencies: Mini-EXIF-Parser fr die
# geläufigsten Tags (ISO=0x8827, ExposureTime=0x829A, FNumber=0x829D,
# LensModel=0xA434). HEIC: macht ffmpeg -> JPEG -> dieser Parser.
# ---------------------------------------------------------------------------
EXIF_TAGS = {
    0x8827: "iso",              # ISOSpeedRatings (SHORT/LONG)
    0x829A: "exposure",         # ExposureTime (RATIONAL)
    0x829D: "fnumber",          # FNumber (RATIONAL)
    0xA434: "lens",             # LensModel (ASCII)
}


def parse_exif_jpeg(path):
    """Mini-EXIF-Parser. Liefert dict mit iso/exposure/fnumber/lens."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return {"_error": str(e)}

    if data[:2] != b"\xff\xd8":
        return {"_error": "kein JPEG (fuer EXIF benoetigt)"}

    # Marker-Struktur durchlaufen und APP1/Exif finden.
    pos = 2
    tiff = None
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            pos += 1
            continue
        marker = data[pos + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            pos += 2
            continue
        length = int.from_bytes(data[pos + 2:pos + 4], "big")
        section = data[pos + 4:pos + 2 + length]
        if marker == 0xE1 and section[:6] == b"Exif\x00\x00":
            tiff = section[6:]
            break
        pos += 2 + length

    if tiff is None:
        return {"_error": "kein EXIF-Block gefunden"}

    # TIFF-Header: Byteorder + IFD0.
    if tiff[:2] == b"II":
        endian = "little"
    elif tiff[:2] == b"MM":
        endian = "big"
    else:
        return {"_error": "TIFF-Header kaputt"}

    def u16(b, off):
        return int.from_bytes(b[off:off + 2], endian)

    def u32(b, off):
        return int.from_bytes(b[off:off + 4], endian)

    out = {}

    def walk_ifd(block, offset):
        """IFD an 'offset' parse; Rueckgabe: naechster EXIF-IFD-Offset."""
        if offset + 2 > len(block):
            return None
        count = u16(tiff, offset)
        exif_ptr = None
        for i in range(count):
            entry = offset + 2 + i * 12
            if entry + 12 > len(tiff):
                break
            if entry + 12 > len(block):
                break
            tag = u16(tiff, entry)
            typ = u16(tiff, entry + 2)
            n = u32(tiff, entry + 4)
            valptr = entry + 8
            size = 0
            if typ == 1 or typ == 6 or typ == 2:
                size = n
            elif typ == 3:
                size = n * 2
            elif typ in (4, 9):
                size = n * 4
            elif typ in (5, 10):
                size = n * 8
            raw = tiff[valptr:valptr + (size if size <= 4 else 4)]
            if size > 4:
                raw = tiff[u32(tiff, valptr):u32(tiff, valptr) + size]

            if tag in EXIF_TAGS and n > 0:
                name = EXIF_TAGS[tag]
                if typ == 3:
                    out[name] = u16(raw, 0) * 1.0
                elif typ in (5, 10):
                    num = u32(raw, 0)
                    den = u32(raw, 4)
                    out[name] = (num / den) if den else 0.0
                elif typ == 2:
                    out[name] = raw.rstrip(b"\x00").decode("latin-1", "replace")
            if tag == 0x8769:  # ExifIFD-Pointer
                exif_ptr = u32(raw, 0)
        return exif_ptr

    main = walk_ifd(tiff, 8)
    if main:
        walk_ifd(tiff, main)
    return out


def build_test_jpeg_with_exif(path):
    """Erzeugt eine kleine JPEG mit EXIF (ISO 320, 1/50s, f/2.2) — nur fr
    lokale Tests des Parsers/Links. TIFF wird programmatisch aufgebaut."""
    import base64
    tiny = base64.b64decode(
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8U"
        "HRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA"
        "/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")

    # TIFF little-endian aufbauen: Header (8) + IFD mit 3 Entries + Datenblock.
    n_entries = 3
    entries = []
    data = bytearray()

    def add_entry(tag, typ, count, value_bytes):
        """value_bytes <= 4: inline ins Value-Feld; sonst Offset in den Block."""
        nonlocal data, entries, n_entries
        if len(value_bytes) <= 4:
            padded = value_bytes + b"\x00" * (4 - len(value_bytes))
            entries.append((tag, typ, count, None, padded))
            return
        while len(data) % 2:
            data.append(0)
        # Datenblock beginnt NACH dem kompletten IFD: 8 Header + 2 count
        # + n_entries*12 + 4 next-IFD.
        off = 8 + 2 + n_entries * 12 + 4 + len(data)
        data += value_bytes
        entries.append((tag, typ, count, off, None))

    add_entry(0x829D, 5, 1, (22).to_bytes(4, "little") + (10).to_bytes(4, "little"))  # f/2.2
    add_entry(0x829A, 5, 1, (1).to_bytes(4, "little") + (50).to_bytes(4, "little"))   # 1/50s
    add_entry(0x8827, 3, 1, (320).to_bytes(2, "little"))                              # ISO 320

    tiff = bytearray()
    tiff += b"II" + (42).to_bytes(2, "little") + (8).to_bytes(4, "little")
    tiff += n_entries.to_bytes(2, "little")
    for tag, typ, count, off, inline in entries:
        tiff += tag.to_bytes(2, "little")
        tiff += typ.to_bytes(2, "little")
        tiff += count.to_bytes(4, "little")
        tiff += inline if inline is not None else off.to_bytes(4, "little")
    tiff += (0).to_bytes(4, "little")               # next IFD = 0
    tiff += data

    app1 = b"\xff\xe1" + (2 + 6 + len(tiff)).to_bytes(2, "big") + b"Exif\x00\x00" + bytes(tiff)
    out = b"\xff\xd8" + app1 + tiny[2:]
    with open(path, "wb") as f:
        f.write(out)
    return path


def video_luma_stats(path, framecap):
    """Mittlere Y-Luminanz eines Frames via ffmpeg -> rawvideo yuv420p."""
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", path, "-vf", "select=eq(n\\,%d)" % max(1, framecap // 2),
        "-vframes", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ]
    try:
        raw = subprocess.run(cmd, capture_output=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not raw:
        return None
    total = sum(raw)
    return total / len(raw) if len(raw) else 0.0


def estimate_iso_from_luma(luma):
    lux = max(luma * 1000.0, 1.0)          # 0..255 -> Lux-Skala
    iso = 120000.0 / (lux + 1.0)
    return int(min(max(iso, 50), 3200))


def send_commands(host, port, commands):
    s = socket.create_connection((host, port), timeout=4)
    s.sendall((" ".join(commands) + "\n").encode())
    resp = s.recv(4096).decode(errors="replace").strip()
    s.close()
    return resp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", help="Bild (JPEG/HEIC) mit EXIF")
    ap.add_argument("--video", help="Video (ffmpeg analysiert Luma)")
    ap.add_argument("--framecap", type=int, default=10,
                    help="ffmpeg waehlt Frame ~framecap//2 (default 10)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--iso", type=float, default=None)
    ap.add_argument("--exposure", type=float, default=None)
    ap.add_argument("--fnumber", type=float, default=None)
    ap.add_argument("--lux", type=float, default=None)
    ap.add_argument("--lens", default=None)
    args = ap.parse_args()

    if not args.image and not args.video:
        ap.error("--image ODER --video erforderlich")

    iso = args.iso
    exp = args.exposure
    fnum = args.fnumber
    lens = args.lens
    lux = args.lux

    if args.image:
        exif = parse_exif_jpeg(args.image)
        print("EXIF:", json.dumps(exif, ensure_ascii=False))
        if "iso" in exif and iso is None:
            iso = float(exif["iso"])
        if "exposure" in exif and exp is None:
            exp = float(exif["exposure"])
        if "fnumber" in exif and fnum is None:
            fnum = float(exif["fnumber"])
        if "lens" in exif and lens is None:
            lens = exif["lens"]

    if args.video:
        luma = video_luma_stats(args.video, args.framecap)
        if luma is None:
            print("[warn] Luma-Messung fehlgeschlagen - nur uebermittelte "
                  "Werte verwenden")
        else:
            print(f"Luma={luma:.1f}")
            if iso is None:
                iso = float(estimate_iso_from_luma(luma))
            # Belichtung: 1/iso-nahes Pendeln, wie NikeCams AEC-Muster
            if exp is None:
                exp = 0.033

    print(f"Sende: iso={iso} exposure={exp} fnumber={fnum} lux={lux} lens={lens}")

    cmds = []
    if iso is not None:
        cmds.append("iso=%d" % int(iso))
    if exp is not None:
        cmds.append("exposure=%.5f" % exp)
    if fnum is not None:
        cmds.append("fnumber=%.2f" % fnum)
    if lux is not None:
        cmds.append("lux=%.1f" % lux)
    if lens is not None:
        lens_clean = lens.replace(" ", "_")   # Port-Token: kein Leerzeichen
        cmds.append("lens=%s" % lens_clean)

    if not cmds:
        print("[warn] nichts zu senden (keine Werte ermittelt)")
        return 1

    try:
        resp = send_commands(args.host, args.port, cmds)
        print("OK:", resp)
        return 0
    except OSError as e:
        print("FEHLER beim Senden:", e)
        print("Hinweis: usbmuxd-Tunnel starten mit")
        print("  python -m pymobiledevice3 usbmux forward 8797 8797")
        return 2


if __name__ == "__main__":
    sys.exit(main())
