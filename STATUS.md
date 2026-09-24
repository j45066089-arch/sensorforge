# SensorForge Pro — Projektstatus

Stand: 2026-09-20 Abend — Maurice schläft, hier wird morgen weitergemacht.

## Repo & CI
- Repo: `j45066089-arch/sensorforge` (Branch `sensorforge`)
- GitHub Actions: waruhachi/theos-action @ roothide/Theos, macOS-Runner
- Artifact-Name: `sensorforgepro-roothide-deb`
- Lokale Kopie: `C:/Users/shosh/SensorForgePro/`

## Verifiziert am Gerät (iPhone 8, iOS 16.7.16, Dopamine2-roothide)
- v1.0–v1.4 gebaut, installiert, `sforge=1` am Status-Port 8797 → Injektion ok
- Hook `BWNodeOutput emitSampleBuffer:` feuert bei laufender Kamera
  (emit ~4k Frames/20s), synth/pass/pds-Zähler steigen
- Status-Port = Lese + Kommandos (`iso= exposure= fnumber= lens= lux= flash= keys?`)
- Sandbox-Nadelöhr gemessen: mediaserverd liest `/var/mobile/Documents/*` NICHT
  (errno 2) → Datei-Transport tot, TCP-Port ist der Kanal
- Build-Verifikation via md5-Vergleich Host-Roh-Deb ↔ Geräte-Dylib

## In Arbeit / offen (morgen)
1. **v1.4-keys?-Vereinfachung committen** — letzter Stand nur lokal gepatcht,
   noch nicht committet/gebaut (Keys-Dump mit raw/valid-Markierung).
2. **v1.4 aufs Gerät** (Bauen → dpkg → kickstart → Kamera → keys? lesen):
   Dump muss die ECHTEN Apple-MakerNote-Keys zeigen (Partials vor Synthese).
3. **ISP-Abgleich**: unser Set (1,2,3,4,5,7,8,9,10,13,15) gegen echte Keys
   aus Schritt 2 angleichen.
4. **SensorForge Link** (`sensorforge_link.py`) — PC-Tool steht, noch
   ungetestet am Live-Gerät; Test: Bild/Video analysieren → Werte auf 8797.
5. Maurice' Wunsch: LordVCAM an + OBS-Quelle + gleiches Video am Phone →
   synth muss steigen (geswappte Frames ohne valide Metals).

## Offene technische Punkte
- uiopen aus SSH startet Kamera-App nicht (roothide) — Maurice öffnet die App
  manuell. Sampler.py (Host) pollt 8797 alle 5s über usbmux forward.
- lens-Werte am Port: Leerzeichen → Unterstrich (Token-Split).
- mediaserverd-Kreisverkehr: Synth-Frames kommen im Pass-Zweig wieder vorbei.

## v1.9 + Dashboard (2026-09-22)
- Foto-EXIF-Pfad FERTIG: Call-Site-Hook capturePhotoWithSettings:delegate: am Gerät belegt
  (Test: ISO 640, F2.8, "SF Test Lens" im HEIC-EXIF nachgewiesen). appFetch-Zähler im Status.
- Dashboard :8081 läuft mit: Slider (ISO/Exposure/F/lux), Video-Dauermodus,
  Bild-Upload (echte EXIF ODER Luma-Generierung für KI-Bilder), LordVCAM-Sync.
- LordVCAM-Sync LEBENDIG: pollt localhost:8080/api/config (video_path, source_type=file),
  analysiert Datei (Bild/Video-Luma -> ISO/Exp/Lux), sendet an Port 8797.
- OFFEN: Exposure-Glättung im Foto (AVCapture rundet auf 1/30), Instagram/TikTok-Bundle-IDs.
- INFO: Dashboard-Prozess als proc_71c96ea92c1a gestartet (Port 8081, :/api/*).
