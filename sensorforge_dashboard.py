#!/usr/bin/env python3
"""
SensorForge Dashboard - lokale Web-Oberflaeche (nur Python-Stdlib).

Start:   python sensorforge_dashboard.py [--port 8081]
Browser: http://127.0.0.1:8081

Voraussetzungen:
  - usbmuxd-Tunnel auf den Status-Port:  python -m pymobiledevice3 usbmux forward 8797 8797
  - SensorForge-Tweak laeuft im mediaserverd (Status-Port 8797)
  - fuer Video-Dauermodus: ffmpeg im PATH

API:
  GET  /api/status                     -> Statuszeile vom Tweak (JSON)
  POST /api/set  {iso,exposure,fnumber,lux,flash,lens} -> Kommandos senden
  POST /api/video/start {video}        -> Dauermodus-Thread starten
  POST /api/video/stop                 -> Thread stoppen
"""
import json
import os
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TARGET_HOST = "127.0.0.1"
TARGET_PORT = 8797
UPLOAD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Tweak-Status lesen / Kommandos senden
# ---------------------------------------------------------------------------
def tweak_roundtrip(commands=""):
    """Eine Verbindung: optional Kommandos senden, immer Antwort lesen."""
    try:
        s = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=4)
        if commands:
            s.sendall((commands + "\n").encode())
        resp = s.recv(4096).decode(errors="replace").strip()
        s.close()
        return resp
    except OSError as e:
        return f"ERR {e}"


def parse_status_line(line):
    """key=value Paare in dict."""
    d = {}
    for tok in line.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                if re.match(r"^-?[0-9]+$", v):
                    d[k] = int(v)
                elif re.match(r"^-?[0-9]*\.[0-9]+$", v):
                    d[k] = float(v)
                else:
                    d[k] = v
            except ValueError:
                d[k] = v
    return d


def video_luma_stats(video, framecap=10):
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", video, "-vf", "select=eq(n\\,%d)" % max(1, framecap // 2),
        "-vframes", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ]
    try:
        raw = subprocess.run(cmd, capture_output=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not raw:
        return None
    return sum(raw) / len(raw)


def image_luma_stats(image):
    """Mittlere Y-Luminanz eines Bildes (JPEG/PNG/HEIC via ffmpeg)."""
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", image, "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ]
    try:
        raw = subprocess.run(cmd, capture_output=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not raw:
        return None
    return sum(raw) / len(raw)


def iso_from_luma(luma):
    lux = max(luma * 4.0, 1.0)
    return int(min(max(120000.0 / (lux + 1.0), 50), 3200))


# ---------------------------------------------------------------------------
# Video-Dauermodus (Hintergrund-Thread)
# ---------------------------------------------------------------------------
class ContinuousController:
    def __init__(self):
        self.lock = threading.Lock()
        self.thread = None
        self.stop_flag = False
        self.video = None
        self.last = {"iso": None, "exp": None, "lux": None, "err": None}

    def start(self, video):
        with self.lock:
            if self.thread and self.thread.is_alive():
                return "laufend"
            self.video = video
            self.stop_flag = False
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()
            return "gestartet"

    def stop(self):
        with self.lock:
            self.stop_flag = True
            self.thread = None
        return "gestoppt"

    def _run(self):
        committed = None
        alpha = 0.35
        while not self.stop_flag:
            luma = video_luma_stats(self.video)
            if committed is None and luma is not None:
                committed = luma * 4.0
            if luma is not None:
                committed = alpha * (luma * 4.0) + (1 - alpha) * committed
            iso = iso_from_luma((committed or 0) / 4.0) if committed else None
            exp = 0.033 * (1.0 + ((committed or 20000.0) / 20000.0 - 1.0) * 0.15)
            exp = min(max(exp, 1.0 / 60.0), 1.0 / 15.0)
            cmds = []
            if iso:
                cmds.append("iso=%d" % iso)
            cmds.append("exposure=%.5f" % exp)
            cmds.append("lux=%.1f" % (committed or 0.0))
            resp = tweak_roundtrip(" ".join(cmds))
            self.last = {"iso": iso, "exp": round(exp, 4),
                         "lux": round(committed or 0.0, 1),
                         "err": resp if resp.startswith("ERR") else None}
            for _ in range(10):
                if self.stop_flag:
                    break
                time.sleep(0.1)


CONTROLLER = ContinuousController()


# ---------------------------------------------------------------------------
# Web-UI
# ---------------------------------------------------------------------------
PAGE = r"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>SensorForge Pro</title>
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin:0; padding:0; font-family: -apple-system, Segoe UI, sans-serif;
       background: var(--background, #0b0f14); color: var(--foreground, #e8edf3); }
.wrap { max-width: 760px; margin: 0 auto; padding: 18px; }
h1 { font-size: 20px; margin: 6px 0 14px; }
.card { background: var(--card, #12181f); border: 1px solid var(--border, #22303c);
        border-radius: 12px; padding: 14px; margin-bottom: 14px; }
.row { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
.lbl { width: 120px; font-size: 13px; color: var(--muted-foreground, #9fb2c3); }
input[type=range] { flex: 1; min-width: 180px; }
input[type=text], input[type=number] { background: #0d1319; color: #e8edf3;
       border: 1px solid #22303c; border-radius: 6px; padding: 6px 8px; width: 100%; }
.btn { background: var(--accent, #3d7df8); color: #fff; border: 0; border-radius: 8px;
       padding: 9px 16px; font-size: 14px; cursor: pointer; }
.btn.ghost { background: #18222c; color: #9fb2c3; }
.badge { display:inline-block; padding: 3px 9px; border-radius: 99px; font-size: 12px; }
.ok { background: #12351f; color: #4ade80; }
.err { background: #3b1416; color: #f87171; }
.mono { font-family: ui-monospace, Consolas, monospace; font-size: 12px;
        white-space: pre-wrap; word-break: break-all; }
#log { height: 130px; overflow-y: auto; }
h2 { font-size: 14px; margin: 0 0 8px; color: #9fb2c3; text-transform: uppercase;
     letter-spacing: .06em; }
</style>
</head>
<body>
<div class="wrap">
  <h1>SensorForge Pro</h1>

  <div class="card">
    <div class="row">
      <span id="conn" class="badge err">verbinde…</span>
      <span id="ver" class="mono"></span>
    </div>
    <div id="stats" class="mono" style="margin-top:10px;"></div>
  </div>

  <div class="card">
    <h2>Sensorwerte (live an den Tweak)</h2>
    <div class="row" style="margin-bottom:8px;">
      <span class="lbl">ISO</span>
      <input type="range" id="iso" min="50" max="3200" step="10" value="200">
      <span id="isoV" class="mono">200</span>
    </div>
    <div class="row" style="margin-bottom:8px;">
      <span class="lbl">Exposure (s)</span>
      <input type="range" id="exp" min="0.005" max="0.1" step="0.0005" value="0.033">
      <span id="expV" class="mono">0.033</span>
    </div>
    <div class="row" style="margin-bottom:8px;">
      <span class="lbl">FNumber</span>
      <input type="range" id="fnum" min="0.5" max="5.6" step="0.1" value="1.8">
      <span id="fnumV" class="mono">1.8</span>
    </div>
    <div class="row" style="margin-bottom:8px;">
      <span class="lbl">Lux (0=auto)</span>
      <input type="range" id="lux" min="0" max="2000" step="5" value="0">
      <span id="luxV" class="mono">0</span>
    </div>
    <div class="row" style="margin-bottom:12px;">
      <span class="lbl">Lens</span>
      <input type="text" id="lens" value="iPhone_8_Back_Camera" style="flex:1;">
    </div>
    <div class="row">
      <button class="btn" onclick="applyAll()">Werte senden</button>
      <button class="btn ghost" onclick="applyFlash()">Flash testen</button>
      <button class="btn ghost" onclick="resetAll()">Reset (iPhone-8-Profile)</button>
    </div>
  </div>

  <div class="card">
    <h2>Video-Dauermodus (Luma → ISO/AEC)</h2>
    <div class="row" style="margin-bottom:12px;">
      <span class="lbl">Video-Datei</span>
      <input type="text" id="vidpath" placeholder="C:\\Pfad\\zu\\clip.mp4" style="flex:1;">
      <input type="file" id="vidfile" accept="video/*" style="display:none;"
             onchange="uploadVideo(this.files[0])">
      <button class="btn" onclick="$('vidfile').click()">📁 Auswählen</button>
    </div>
    <div class="row">
      <button class="btn" onclick="vidStart()">Start</button>
      <button class="btn ghost" onclick="vidStop()">Stop</button>
      <span id="vidinfo" class="mono"></span>
    </div>
  </div>

  <div class="card">
    <h2>Bild-EXIF übernehmen</h2>
    <div class="row">
      <input type="file" id="imgfile" accept="image/*" style="display:none;"
             onchange="uploadImage(this.files[0])">
      <button class="btn" onclick="$('imgfile').click()">🖼 Bild auswählen (EXIF → Tweak)</button>
      <span id="imginfo" class="mono"></span>
    </div>
  </div>

  <div class="card">
    <h2>Log</h2>
    <div id="log" class="mono"></div>
  </div>
</div>

<script>
let STATUS = {};
function $(id){ return document.getElementById(id); }

function log(msg){
  const el = $("log");
  const t = new Date().toTimeString().slice(0,8);
  el.textContent += "[" + t + "] " + msg + "\n";
  el.scrollTop = el.scrollHeight;
}

async function poll(){
  try {
    const r = await fetch("/api/status");
    const j = await r.json();
    STATUS = j.status || {};
    $("conn").className = "badge ok";
    $("conn").textContent = "Tweak verbunden";
    $("ver").textContent = "ver=" + (STATUS.ver || "?");
    const vi = $("vidinfo");
    if (j.video && j.video.running) {
      vi.textContent = `Dauermodus: iso=${j.video.iso} exp=${j.video.exp} lux=${j.video.lux}`;
    } else {
      vi.textContent = "";
    }
    const s = $("stats");
    s.textContent = `emit=${STATUS.emit??0}  synth=${STATUS.synth??0}  pass=${STATUS.pass??0}  pts=${STATUS.pts??0}
walkIso=${STATUS.walkIso??0}  walkExposure=${STATUS.walkExposure??0}  lux=${STATUS.lux??0}  lensPos=${STATUS.lensPos??0}`;
  } catch(e) {
    $("conn").className = "badge err";
    $("conn").textContent = "getrennt";
  }
}

const sliders = [["iso","isoV",1],["exp","expV",1],["fnum","fnumV",1],["lux","luxV",1]];
for (const [id, lbl] of sliders) {
  $(id).addEventListener("input", () => { $(lbl).textContent = $(id).value; });
}

async function post(path, body){
  try {
    const r = await fetch(path, {method:"POST",
      headers:{"Content-Type":"application/json"}, body: JSON.stringify(body||{})});
    const j = await r.json();
    log("OK: " + (j.reply || j.msg || ""));
  } catch(e) { log("FEHLER: " + e); }
}

function applyAll(){
  post("/api/set", {iso: +$("iso").value, exposure: +$("exp").value,
    fnumber: +$("fnum").value, lux: +$("lux").value, lens: $("lens").value});
  log("Sende: iso="+$("iso").value+" exp="+$("exp").value+
      " f="+$("fnum").value+" lux="+$("lux").value+" lens="+$("lens").value);
}
function applyFlash(){ post("/api/set", {flash: 1}); log("Flash-Impuls"); }
function resetAll(){
  $("iso").value=200; $("isoV").textContent=200;
  $("exp").value=0.033; $("expV").textContent=0.033;
  $("fnum").value=1.8; $("fnumV").textContent=1.8;
  $("lux").value=0; $("luxV").textContent=0;
  $("lens").value="iPhone_8_Back_Camera";
  applyAll();
}
function vidStart(){ post("/api/video/start", {video: $("vidpath").value}); }
function vidStop(){ post("/api/video/stop"); }

async function uploadVideo(file){
  if (!file) return;
  const fd = new FormData();
  fd.append("file", file);
  try {
    const r = await fetch("/api/upload/video", {method:"POST", body: fd});
    const j = await r.json();
    $("vidpath").value = j.file || "";
    $("vidinfo").textContent = "hochgeladen: " + (j.file||"") ;
    log("Video hochgeladen: " + j.file + " -> " + (j.msg||""));
  } catch(e){ log("Upload-FEHLER: " + e); }
}

async function uploadImage(file){
  if (!file) return;
  const fd = new FormData();
  fd.append("file", file);
  try {
    const r = await fetch("/api/upload/image", {method:"POST", body: fd});
    const j = await r.json();
    const gen = (j.exif && j.exif.generated) ? " (generiert aus Bildhelligkeit)" : "";
    $("imginfo").textContent = "EXIF" + gen + ": " + JSON.stringify(j.exif||{});
    log("Bild: " + (j.file||"") + gen + " -> " + (j.reply||""));
    poll();
  } catch(e){ log("Upload-FEHLER: " + e); }
}

setInterval(poll, 1000);
poll();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = urlparse(self.path)
        if p.path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif p.path == "/api/status":
            line = tweak_roundtrip()
            status = parse_status_line(line)
            running = bool(CONTROLLER.thread and CONTROLLER.thread.is_alive())
            self._send(200, {"status": status,
                             "video": {"running": running, **CONTROLLER.last}})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        p = urlparse(self.path)
        ctype = self.headers.get("Content-Type", "")
        # Multipart-Upload: /api/upload/video bzw /api/upload/image
        if p.path in ("/api/upload/video", "/api/upload/image") and \
                "multipart/form-data" in ctype:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            saved = self._save_upload(raw, ctype)
            kind = "video" if p.path.endswith("/video") else "image"
            if saved is None:
                self._send(400, {"error": "keine Datei im Request"})
                return
            if kind == "video":
                msg = CONTROLLER.start(saved)
                self._send(200, {"msg": msg, "file": saved})
            else:
                # Bild: EXIF lesen (oder generieren), Werte an den Tweak.
                exif = self._read_image_exif(saved)
                cmds = []
                if exif.get("iso"):
                    cmds.append("iso=%d" % int(float(exif["iso"])))
                if exif.get("exposure"):
                    cmds.append("exposure=%.5f" % float(exif["exposure"]))
                if exif.get("fnumber"):
                    cmds.append("fnumber=%.2f" % float(exif["fnumber"]))
                if exif.get("lens"):
                    cmds.append("lens=%s" % str(exif["lens"]).replace(" ", "_"))
                # generierte Luma -> korrelierten Lux mitsenden
                if exif.get("luma") is not None:
                    cmds.append("lux=%.1f" % (float(exif["luma"]) * 4.0))
                reply = tweak_roundtrip(" ".join(cmds)) if cmds else "kein EXIF - nichts gesendet"
                self._send(200, {"reply": reply, "exif": exif, "file": saved})
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        if p.path == "/api/set":
            cmds = []
            if "iso" in body:
                cmds.append("iso=%d" % int(float(body["iso"])))
            if "exposure" in body:
                cmds.append("exposure=%.5f" % float(body["exposure"]))
            if "fnumber" in body:
                cmds.append("fnumber=%.2f" % float(body["fnumber"]))
            if "lux" in body:
                cmds.append("lux=%.1f" % float(body["lux"]))
            if "flash" in body and body["flash"]:
                cmds.append("flash=1")
            if "lens" in body and body["lens"]:
                cmds.append("lens=%s" % str(body["lens"]).replace(" ", "_"))
            reply = tweak_roundtrip(" ".join(cmds)) if cmds else "keine Kommandos"
            self._send(200, {"reply": reply})
        elif p.path == "/api/video/start":
            msg = CONTROLLER.start(str(body.get("video", "")))
            self._send(200, {"msg": msg})
        elif p.path == "/api/video/stop":
            msg = CONTROLLER.stop()
            self._send(200, {"msg": msg})
        else:
            self._send(404, {"error": "not found"})

    # ------------------------------------------------------------------
    # Upload-Helfer
    # ------------------------------------------------------------------
    def _save_upload(self, raw, ctype):
        # boundary extrahieren
        m = re.search(r"boundary=([^;]+)", ctype)
        if not m:
            return None
        boundary = m.group(1).strip().strip('"').encode()
        parts = raw.split(b"--" + boundary)
        for part in parts:
            if b"filename=\"" in part:
                head, _, content = part.partition(b"\r\n\r\n")
                fname = re.search(rb'filename="([^"]+)"', head)
                name = fname.group(1).decode("utf-8", "replace") if fname else "upload.bin"
                # trailing CRLF vor boundary entfernen
                content = content.rsplit(b"\r\n", 1)[0]
                safe = os.path.basename(name)
                dest = os.path.join(UPLOAD_DIR, safe)
                with open(dest, "wb") as f:
                    f.write(content)
                return dest
        return None

    def _read_image_exif(self, path):
        """Bild-EXIF lesen. Wenn KEIN EXIF (z. B. KI-generierte Bilder):
        Luma-Analyse via ffmpeg und Sensorwerte GENERIEREN
        (ISO aus Helligkeit, Exposure-Pendel, f/1.8 iPhone-8-Default)."""
        exif = {}
        try:
            import sys
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from sensorforge_link import parse_exif_jpeg
            exif = parse_exif_jpeg(path) or {}
        except Exception:
            exif = {}
        if "_error" in exif:
            exif = {}

        # Nur als "vollstaendig" werten, wenn die Kernfelder da sind.
        complete = ("iso" in exif and "fnumber" in exif)
        if complete:
            return exif

        # Sonst: generieren.
        luma = image_luma_stats(path)
        if luma is None:
            return {"error": "kein EXIF und Luma nicht lesbar"}
        lux = max(luma * 4.0, 1.0)
        iso = int(min(max(120000.0 / (lux + 1.0), 50), 3200))
        exp = 0.033 * (1.0 + (lux / 20000.0 - 1.0) * 0.15)
        exp = min(max(exp, 1.0 / 60.0), 1.0 / 15.0)
        # Vorhandene Teilfelder (z. B. nur lens) beibehalten, fehlende erzeugen.
        exif.setdefault("iso", iso)
        exif.setdefault("exposure", round(exp, 5))
        exif.setdefault("fnumber", 1.8)
        exif.setdefault("lens", "iPhone 8 Back Camera")
        exif["generated"] = True
        exif["luma"] = round(luma, 1)
        return exif

    def log_message(self, *a):
        pass


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8081)
    args = ap.parse_args()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"SensorForge Dashboard: http://127.0.0.1:{args.port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
