# SensorForge Pro — Projektbericht mit allen Pfaden & Funktionsweise

Stand: 26.09.2026 · Letzter verifizierter Zustand: v1.9 am Gerät + Dashboard mit LordVCAM-Sync

---

## 1. DAS PROJEKT IN EINEM SATZ

SensorForge Pro ist ein iOS-Tweak (mediaserverd + Kamera-App) + PC-Dashboard-Toolchain,
das an Videoframes und Fotos eines iPhones **plausible, dynamische Sensor-Metadaten**
(EXIF {Exif} + Apple-MakerNote + Video-ISP-Keys wie LuxLevel/ispDGain/DigitalFlash/
LensPosition) anhängt — für den Fall, dass die Frames von einem Pfeed-Tool
(LordVCAM/OBS) kommen und ohne echte Sensor-Daten ankommen, woran moderne Apps
abstürzen oder erkennen würden, dass es keine echte Linse ist.

---

## 2. LOKALE PROJEKT-PFADE (PC)

| Pfad | Zweck |
|---|---|
| `C:\Users\shosh\SensorForgePro\` | Projektwurzel (Quellcode des Tweaks + PC-Tools) |
| `C:\Users\shosh\SensorForgePro\Tweak.x` | Logos-Quellcode (iOS-Tweak, Herzstück) |
| `C:\Users\shosh\SensorForgePro\Makefile` | Theos-Build-Datei (roothide-Package-Scheme) |
| `C:\Users\shosh\SensorForgePro\control` | Debian-Paket-Metadaten (Version 1.9) |
| `C:\Users\shosh\SensorForgePro\SensorForgePro.plist` | Filter-Plist (mediaserverd + com.apple.camera) |
| `C:\Users\shosh\SensorForgePro\.github\workflows\sensorforge-ios16.yml` | CI-Build (GitHub Actions, macOS, theos-action) |
| `C:\Users\shosh\SensorForgePro\sensorforge_dashboard.py` | Web-Dashboard (Port 8081, Python-Stdlib) |
| `C:\Users\shosh\SensorForgePro\sensorforge_link.py` | CLI: Bild/Video → Werte an Port 8797 (inkl. Dauermodus) |
| `C:\Users\shosh\SensorForgePro\sampler.py` | Host-Diagnose: pollt alle 5 s den Zustandsport |
| `C:\Users\shosh\SensorForgePro\pull_photo.py` | Fotos vom iPhone via AFC (pymobiledevice3) |
| `C:\Users\shosh\SensorForgePro\heic_exif.py` / `heic_exif2.py` / `heic_exif3.py` | HEIC/EXIF-Parser (3 Stufen; heic_exif3.py ist der funktionierende: sucht `Exif\0\0`+TIFF direkt) |
| `C:\Users\shosh\SensorForgePro\artifacts\` | Gebaute `.deb`-Dateien + extrahierte Dylibs |
| `C:\Users\shosh\SensorForgePro\uploads\` | Dashboard-Uploads (Bild/Video) |
| `C:\Users\shosh\SensorForgePro\test\` | Testbilder/-videos/Fotos vom Gerät |
| `C:\Users\shosh\SensorForgePro\STATUS.md` | Projekt-Chronik (lies das bei jedem Neustart zuerst) |

**Git-Repo:** `j45066089-arch/sensorforge` (Branch `sensorforge`)

---

## 3. GERÄTE-PFADE (iPhone 8, iOS 16.7.16, Dopamine2-roothide)

| Pfad | Zweck |
|---|---|
| `/var/jb/usr/lib/TweakInject/SensorForgePro.dylib` | ElleKit-Tweak-Injektion (Daemon) |
| `/var/jb/Library/MobileSubstrate/DynamicLibraries/SensorForgePro.dylib` | Substrate-kompatibles Ziel (zweite Kopie) |
| `/var/containers/Bundle/Application/.jbroot-A634CDAB8E5ACEEE/usr/lib/TweakInject/SensorForgePro.dylib` | Dritte Kopie (jbroot-Pfad) |
| `/var/containers/Bundle/Application/.jbroot-A634CDAB8E5ACEEE/Library/MobileSubstrate/DynamicLibraries/SensorForgePro.dylib` | Vierte Kopie |
| (dieselben Pfade als `SensorForgePro.plist`) | Filter-Plist an jedem Ziel |
| **Status-Port 8797** | Loopback-TCP im Daemon: Lese- + Kommando-Kanal |

> ⚠️ **jbroot-Pfad ist ZUFÄLLIG pro Jailbreak.** Nach jedem Re-Jailbreak neu ermitteln:
> `ls -d /var/containers/Bundle/Application/.jbroot-*`

---

## 4. WIE ES FUNKTIONIERT — DIE 3 SCHICHTEN

### Schicht 1: Tweak (Daemon + App)

**Datei:** `Tweak.x` · Zielprozesse: `mediaserverd` (Daemon) + `com.apple.camera` (App)

| Hook | Prozess | Aufgabe |
|---|---|---|
| `BWNodeOutput emitSampleBuffer:` | mediaserverd | Video-Pfad: hängt an Frames das `MetadataDictionary` mit `{Exif}` + `{MakerApple}` + Video-ISP-Keys an (LuxLevel, ispDGain, DigitalFlash, LensPosition, FocusConfidence, FocusDistance, AGC, DGain) |
| `AVCapturePhotoOutput capturePhotoWithSettings:delegate:` | Kamera-App | Foto-Pfad: setzt vor der Aufnahme `{Exif}` in die Settings (BWPhotoEncoderNode baut Foto-EXIF ausschließlich daraus) |
| `AVCapturePhotoSettings metadata` (Getter) | Kamera-App | Fallback-Pfad (zusätzlich) |

**Kernregeln (alle eingehalten):**
- **Keine Reallokation:** Es wird NIE ein neuer CMSampleBuffer/CVPixelBuffer erzeugt — nur `CMSetAttachment` auf dem bestehenden Buffer.
- **Passthrough:** Ist das Metadaten-Dictionary bereits valide → Finger weg (Transparenz).
- **Random-Walk:** ISO (Basis ±5) + Exposure (~0.033 s) + LensPosition (0.78) pendeln mit Rückstellkraft — wie ein echter AEC-Loop.
- **Fotometrische Korrelation:** `Lux = 250·F²/(ISO·t)` — LuxLevel passt mathematisch zu ISO & Belichtung.
- **PTS-Monotonie:** PTS wird in-place auf die Host-Clock gesetzt (nie zurück).

**Status-Port-Protokoll (8797):**
```
Lesen:            (leere Verbindung) → Statuszeile
Kommandos:        iso=320 exposure=0.02 fnumber=2.2 lux=180 lens=SF_Lens flash=1 keys?
Antwort-Beispiel: sforge=1 ver=1.9 emit=60638 synth=26672 pass=33966 ...
                  cfgIso=200 cfgExposure=0.0330 cfgFNumber=1.80 lens=iPhone_8_Back_Camera
                  walkIso=182 walkExposure=0.0291 lux=644.7 lensPos=0.764 flash=0 dump=1 appFetch=3
```
Marker: `appfoto` zählt App-Foto-Fetches (`appFetch`) — Beweis, dass der Foto-Hook greift.

### Schicht 2: Dashboard (PC, Port 8081)

**Datei:** `sensorforge_dashboard.py` · Start: `cd C:\Users\shosh\SensorForgePro && python sensorforge_dashboard.py`
Browser: `http://127.0.0.1:8081`

| Element | Funktion |
|---|---|
| Live-Statuskarte | emit/synth/pass-Zähler, Version, Walk-Werte, Lux (Poll 1 s) |
| Slider | ISO (50–3200), Exposure, FNumber, Lux (0=auto), Lens → per „Werte senden" an 8797 |
| Video-Dauermodus | Videopfad eintragen + Start/Stop: fortlaufendes Luma→ISO (AEC-Trägheit α=0.35, 1 s-Takt) |
| 📁 Video-Auswahl | Datei-Upload → speichert in `uploads/` → startet Dauermodus |
| 🖼 Bild-Auswahl | Upload → echte EXIF lesen **oder** bei EXIF-losen KI-Bildern automatisch generieren (Luma→ISO/Exposure/Lux, F1.8) |
| LordVCAM-Sync | Pollt `http://localhost:8080/api/config` (source_type/video_path). Wechselst du im LordVCAM-Dashboard die Quelle, analysiert SensorForge die neue Datei automatisch und schiebt ISO/Exposure/Lux ans Gerät |

**Dashboard-API:**
```
GET  /api/status        → Tweak-Status + Video/Sync-Zustand
POST /api/set           → {iso, exposure, fnumber, lux, flash, lens}
POST /api/video/start   → {video: Pfad}
POST /api/video/stop
POST /api/lvcam/start   → LordVCAM-Sync aktivieren
POST /api/lvcam/stop
POST /api/upload/video  → multipart-Video-Upload
POST /api/upload/image  → multipart-Bild-Upload (EXIF lesen/generieren + senden)
```
> Voraussetzung: USB-Tunnel `python -m pymobiledevice3 usbmux forward 8797 8797` muss laufen.

### Schicht 3: CLI-Link (PC)

**Datei:** `sensorforge_link.py`

```
python sensorforge_link.py --image bild.jpg          # EXIF → 8797
python sensorforge_link.py --video clip.mp4          # Luma → ISO → 8797
python sensorforge_link.py --video c.mp4 --continuous  # Dauermodus, 1 s-Takt
```

---

## 5. WAS AM GERÄT VERIFIZIERT IST

- ✅ Injektion: `sforge=1 ver=1.9` am Port nach jedem kickstart (`launchctl kickstart -k user/foreground/com.apple.mediaserverd`)
- ✅ Video-Pfad: emit/synth/pass steigen bei laufender Kamera (LordVCAM-Frames kommen ohne Metadaten → synth greift)
- ✅ Foto-Pfad: `appFetch=N` zählt; Testfoto bewies ISO 640 / F2.8 / „SF Test Lens" im HEIC-EXIF
- ✅ Random-Walk: walkIso pendelt 195–205, exposure 0.032–0.0335
- ✅ Lux-Korrelation: 118–126 bzw. aus Luma generiert (617 lux bei dunkelstem Testbild → ISO 960)
- ✅ LordVCAM-Sync: erkennt aktive Datei (z. B. `hf_*.png`) und übernimmt automatisch
- ❌ mediaserverd kann `/var/mobile/Documents/*` NICHT lesen (Sandbox, errno 2) → Datei-Transport tot, Port 8797 ist der Kanal

---

## 6. OFFEN / NÄCHSTE SCHRITTE

1. **Exposure-Glättung im Foto** — AVCapture glättet 1/15 s → 1/30 s im HEIC (rundet intern)
2. **Instagram/TikTok-Bundle-IDs** in `SensorForgePro.plist` → `Bundles`-Array erweitern (com.burbn.instagram, com.zhiliaoapp.musically), damit der Foto-Hook auch in Dritt-Apps greift
3. **Front-Kamera/Analyse-Pfad** (dein gemeldetes Problem): LordVCAM hookt nur BWNodeOutput/Preview —
   Face-/Distance-Erkennung der Apps läuft über AVCaptureVideoDataOutput und sieht weiter die ECHTE
   Front-Kamera. Fix würde App-seitigen didOutputSampleBuffer-Hook + Quellen-Spiegelung brauchen.
4. Noch UNSORGIERT: alter Version-String („v1.4" in ctor-Logzeile), Exposure-Detail im Foto-Pfad.

---

## 7. GEBRÄUCHLICHE KOMMANDOS (Spickzettel)

```bash
# USB-Tunnel (SSH + Status-Port)
python -m pymobiledevice3 usbmux forward 2222 22        # SSH zugang
python -m pymobiledevice3 usbmux forward 8797 8797      # Status-Port

# Tweak neu laden
ssh root@127.0.0.1 -p 2222    # PW: gespeichert (mobile/7789, root per user-angabe)
launchctl kickstart -k user/foreground/com.apple.mediaserverd

# Status ablesen (Device-Seite)
bash -c 'exec 3<>/dev/tcp/127.0.0.1/8797; cat <&3'

# Wert setzen
bash -c 'exec 3<>/dev/tcp/127.0.0.1/8797; printf "iso=320 exposure=0.02 fnumber=2.2" >&3; cat <&3'

# Dashboard
cd C:\Users\shosh\SensorForgePro && python sensorforge_dashboard.py   # dann http://127.0.0.1:8081

# Neues Deb bauen (per GitHub Actions Push auf Branch sensorforge)
cd C:\Users\shosh\SensorForgePro
git push origin sensorforge
# → CI baut .deb, download über: gh run download <run-id> -n sensorforgepro-roothide-deb

# Foto vom Gerät
python pull_photo.py
# dann HEIC-EXIF prüfen:
python heic_exif3.py   # (PATH oben in der Datei anpassen)
```
