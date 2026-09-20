// ============================================================================
//  SensorForge Pro — Tweak.x
// ----------------------------------------------------------------------------
//  Eigenstaendiger iOS-System-Tweak (separates, unabhaengiges Paket).
//  Zielumgebung:    iPhone 8 (iPhone10,4), iOS 16.6 - 16.7.16
//  Jailbreak:       Dopamine 2 (roothide / rootless, ElleKit)
//  Zielprozess:     mediaserverd  (= CAPTURE-DAEMON auf iOS 16; hier laufen
//                   die BW-*-Knoten und der FigCapture-Pfad)
//
//  ZWECK (Hardware-Emulation fuer defekte Kamerasensoren):
//   Moderne Apps stuerzen ab, wenn Video-Frames ohne valide Sensordaten
//   ankommen. Dieser Tweak arbeitet deshalb DOWNSTREAM (Post-Processing-
//   Verfahren): er haengt an bereits existierende Frames ein plausibles,
//   dynamisches Metadata-Dictionary an. Er liest KEINE Videodateien und
//   veraendert KEINE Pixel.
//
//  SCHUTZREGELN (Kollisionsfreiheit mit anderen Kamera-Tweaks, z. B. LordVCAM):
//   * Hook-Ebene maximal downstream: -[BWNodeOutput emitSampleBuffer:]
//     Zu diesem Zeitpunkt haben Frame-Swap-Tweaks (die z. B. am
//     BWMultiStreamCameraSourceNode oder an Sink-Knoten haengen und ihren
//     Austausch %orig-ketten-seitig bereits erledigt haben) ihren Swap
//     abgeschlossen. Wir ergaenzen danach nur noch fehlende METADATEN.
//   * KEINE Reallokation: Es wird niemals ein neuer CMSampleBufferRef oder
//     CVPixelBufferRef erzeugt. Es laufen ausschliesslich in-place
//     Attachment-Operationen (CMSetAttachment) auf dem bestehenden Buffer.
//     Damit werden die Speicherbereiche anderer Tweaks nicht verletzt.
//   * Passthrough: Ein bereits vorhandenes, valides Metadata-Dictionary wird
//     NICHT angefasst. Nur fehlende oder korrupte Daten werden synthetisiert.
//
//  Kern-Schnittstellen (CoreMedia / FigCapture/"Avery"-Graphen):
//   -------------------------------------------------------------------------
//   CMSampleBufferRef: Zeit-basierter Container, der Video-BlockBuffer +
//     FormatDescription + Timing-Info + ATTACHMENTS buendelt.
//     Attachments liegen am Buffer selbst (via CMSetAttachment) und werden
//     von AVFoundation unter dem Key kCMSampleBufferAttachmentKey_Metadata-
//     Dictionary — exakter CFString-Wert: " MetadataDictionary" (fuehrendes
//     Leerzeichen, kein Tippfehler!) — als NSDictionary gelesen.
//   CMSetAttachment(): zerstörungsfreies Setzen eines Attachments auf einem
//     bereits existierenden Buffer — die EINZIGE Mutation, die hier laeuft.
//   CMSampleBufferSetOutputPresentationTimeStamp(): In-place-Update des
//     Output-PTS, KEIN neuer Buffer noetig.
//   CMClockGetTime(CMClockGetHostTimeClock()): Host-Zeitquelle. Aus deren
//     CMTime wird der neue PTS abgeleitet, damit die PTS-Monotonie erhalten
//     bleibt (kein A/V-Ruckeln). Der Capture-Pfad taktet ohnehin gegen die
//     Host-Clock, daher ist das konsistent zum echten Sensor.
//   BWNodeOutput (Avery-Graph, mediaserverd): letzte gemeinsame Einspeise-
//     Stufe des BW-Graphen. Proven: emitSampleBuffer: speist Preview,
//     Foto-Pfad UND Recording — ein Hook hier deckt alle Konsumenten ab.
//
//  Logos-OS-Legende: %hook = ObjC-Methode ersetzen, %orig = Original rufen,
//  %ctor = Konstruktor beim Laden in den Zielprozess.
// ============================================================================

#import <Foundation/Foundation.h>

// CoreMedia ist ein public SDK-Framework (CoreMedia.framework); die Header
// liefern die hier genutzten Opaque-Typen und Funktionen:
//   CMTime / CMClock / CMSampleBuffer / CMAttachment (via <CoreMedia/CoreMedia.h>)
#include <CoreMedia/CoreMedia.h>
// ImageIO liefert die EXIF-Schluessel-Konstanten (kCGImagePropertyExif*).
#include <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

// ----------------------------------------------------------------------------
// EXAKTE Attachment-Keys (so wie AVFoundation sie im Frame liest).
// Der MetadataDictionary-Key beginnt MIT EINEM LEERZEICHEN — das ist kein
// Bug, sondern der tatsaechliche CoreMedia-String aus CMFormatDescription.h:
//   kCMSampleBufferAttachmentKey_MetadataDictionary = CFSTR(" MetadataDictionary")
// kCMSampleBufferAttachmentKey_MetadataDictionary ist in den iOS-SDK-Headern
// NICHT sichtbar exportiert -> wir verwenden das CFSTR-Literal direkt.
// ----------------------------------------------------------------------------
#define SF_METADATA_KEY       CFSTR(" MetadataDictionary")
#define SF_EXIF_DICT_KEY      @"{Exif}"
#define SF_EXIF_DICT_KEY_CF   CFSTR("{Exif}")

// ----------------------------------------------------------------------------
// iPhone-8-Hardware-Profil (Rueckkamera, A11):
//   Blende:            f/1.8         (FNumber = 1.8)
//   Linse:             "iPhone 8 Back Camera"
//   Basis-ISO:         ~200          (simuliert als Fluktuation 195..205)
//   Basis-Belichtung:  ~1/30 s       (ExposureTime ~0.033 s, passt zu 30 fps)
// ----------------------------------------------------------------------------
#define SF_EXIF_LENS_MODEL    @"iPhone 8 Back Camera"
#define SF_EXIF_FNUMBER       (@1.8)   // NSNumber, ImageIO erwartet Zahl
#define SF_ISO_BASE           200
#define SF_ISO_DELTA          5        // Pendelband +-5 => 195..205
#define SF_EXPOSURE_BASE_S    0.033    // 1/30 s
#define SF_EXPOSURE_JITTER_S  0.0006   // minimale zeitabhaengige Schwankung

// ----------------------------------------------------------------------------
// xorshift32-PRNG. Warum nicht libc rand()?
//   * Der Hook laeuft mit 30+ fps, teils aus mehreren Konsumenten-Threads.
//   * rand() hat einen globalen, lockgeschuetzten libc-State — Locking im
//     Hot-Path eines Capture-Graphen ist tabu.
//   * xorshift auf einem eigenen _Atomic-Wort ist sperrlos, deterministisch
//     und billig genug (3 XOR/Shift pro Zahl).
// ----------------------------------------------------------------------------
static _Atomic(uint32_t) sf_rng_state = 0;

static uint32_t sf_rand_u32(void) {
    uint32_t x = atomic_load_explicit(&sf_rng_state, memory_order_relaxed);
    if (x == 0) x = (uint32_t)(mach_absolute_time() & 0xFFFFFFFFU) | 1U;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    atomic_store_explicit(&sf_rng_state, x, memory_order_relaxed);
    return x;
}

// Float in [lo, hi) — fuer die Sensorfluktuation genau genug.
static double sf_rand_range(double lo, double hi) {
    double unit = (double)sf_rand_u32() / 4294967296.0; // [0,1)
    return lo + unit * (hi - lo);
}

// ----------------------------------------------------------------------------
// Validataet: Das (bereits am Buffer haengende) Dictionary gilt als VALIDE,
// wenn es ein NSDictionary ist und im "{Exif}"-Unter-Dictionary eine FNumber
// oder ein ISOSpeedRatings-Eintrag existiert. Dann => Passthrough: wir
// fassen NICHTS an. (Der echte Sensor bzw. andere Tweaks setzen diese
// Struktur regulaer; fehlt FNumber/ISO, ist das Bild korrupt/unvollstaendig.)
// ----------------------------------------------------------------------------
static BOOL sf_metadata_is_valid(NSDictionary *existing) {
    if (existing == nil || ![existing isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *exif = [existing objectForKey:SF_EXIF_DICT_KEY];
    if (exif == nil || ![exif isKindOfClass:NSDictionary.class]) return NO;
    if ([exif objectForKey:(NSString *)kCGImagePropertyExifFNumber] != nil) return YES;
    if ([exif objectForKey:(NSString *)kCGImagePropertyExifISOSpeedRatings] != nil) return YES;
    return NO;
}

// EXIF-Zeitstempel im exiftool-Format "yyyy:MM:dd HH:mm:ss" — bewusst OHNE
// NSDateFormatter (teure Allokation pro Frame, nicht threadsicher):
// localtime_r + snprintf ist Hot-Path-tauglich.
static NSString *sf_exif_timestamp(void) {
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char buf[24];
    snprintf(buf, sizeof(buf), "%04d:%02d:%02d %02d:%02d:%02d",
             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    return [NSString stringWithUTF8String:buf];
}

// ----------------------------------------------------------------------------
// Synthese des Exif-Dicts (iPhone-8-Profil, minimal zeitabhaengig):
//   * FNumber:            fest 1.8
//   * LensModel:          "iPhone 8 Back Camera"
//   * ISOSpeedRatings:    NSArray mit einem Wert, Pendeln 195..205
//   * ExposureTime:       ~1/30 s mit +-0.6 ms Jitter
//   * DateTimeOriginal:   laufende Systemzeit (exiftool-Format)
// Die Werte entsprechen bewusst dem echten iPhone-8-Video-Profil, damit
// App-seitige Auto-Exposure-Logik die Daten als plausibel akzeptiert.
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_exif(void) {
    NSMutableDictionary *exif = [NSMutableDictionary dictionaryWithCapacity:5];

    [exif setObject:SF_EXIF_FNUMBER
             forKey:(NSString *)kCGImagePropertyExifFNumber];

    [exif setObject:SF_EXIF_LENS_MODEL
             forKey:(NSString *)kCGImagePropertyExifLensModel];

    int iso = SF_ISO_BASE + (int)sf_rand_range(-SF_ISO_DELTA, SF_ISO_DELTA + 1);
    [exif setObject:@[ @(iso) ]
             forKey:(NSString *)kCGImagePropertyExifISOSpeedRatings];

    double exposure = SF_EXPOSURE_BASE_S
                    + sf_rand_range(-SF_EXPOSURE_JITTER_S, SF_EXPOSURE_JITTER_S);
    [exif setObject:@(exposure)
             forKey:(NSString *)kCGImagePropertyExifExposureTime];

    // Datum/Zeit nur ca. 1x pro Sekunde neu (Sekundengenauigkeit): billig.
    [exif setObject:sf_exif_timestamp()
             forKey:(NSString *)kCGImagePropertyExifDateTimeOriginal];

    return exif;
}

// ----------------------------------------------------------------------------
// PTS-Aktualisierung: In-place via CMSampleBufferSetOutputPresentation-
// TimeStamp. Zeitbasis = Host-Uhr (CMClockGetTime(CMClockGetHostTimeClock())),
// also der Takt, gegen den der Capture-Pfad ohnehin laeuft. Monotonie-Guard:
// der neue PTS faellt nie hinter den alten zurueck (Decodern/Demuxern wird
// so kein Ruecksprung zugemutet => kein Ruckeln).
// ----------------------------------------------------------------------------
static void sf_update_pts(CMSampleBufferRef buf) {
    if (buf == NULL) return;

    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTime oldPts   = CMSampleBufferGetOutputPresentationTimeStamp(buf);
    CMTime newPts   = hostTime;

    // Wenn der Host-Takt (warum auch immer) hinter dem Frame-PTS haenge:
    // alten PTS um ein Minimum nach vorne schieben statt zurueckzuspringen.
    // Timescale 1.000.000 (Mikrosekunden) => 0.1 ms bleiben darstellbar.
    if (CMTIME_IS_VALID(oldPts) && CMTimeCompare(hostTime, oldPts) < 0) {
        newPts = CMTimeAdd(oldPts, CMTimeMakeWithSeconds(0.0001, 1000000));
    }

    if (CMTIME_IS_VALID(newPts)) {
        CMSampleBufferSetOutputPresentationTimeStamp(buf, newPts);
    }
}

// ============================================================================
// HOOK — maximale Downstream-Stufe im mediaserverd-Capture-Pfad.
//
// Warum -[BWNodeOutput emitSampleBuffer:]?
//   * BWNodeOutput ist die letzte gemeinsame Ausgabe-Stufe der BW-Graphen
//     (Avery/FigCapture): Preview, Still und Movie-Recording fliessen HIER
//     hindurch. Ein einziger Hook deckt alle Konsumenten ab.
//   * Frame-Swap-Tweaks (LordVCAM etc.) tauschen ihre Pixel ebenfalls in
//     dieser Kette bzw. frueher im Graphen. Attachments (diese Dylib) und
//     Pixel-Bytes (andere Tweaks) liegen auf getrennten Lanes desselben
//     Buffer-Objekts — ein reines Content-Add-on, das mit jedem Swap-Tweak
//     koexistiert, solange wir weder Buffer noch Pixel neu alloziieren.
//
// Ablauf im Hook:
//   (1) Guard: kein NULL-Buffer.
//   (2) Passthrough-Check: valides Metadata-Dictionary am Buffer => Finger
//       weg, es wird NICHTS veraendert (weder Dictionary noch PTS).
//   (3) Simulation: nur bei fehlenden/korrupten Metadaten -> Exif-Dictionary
//       bauen, per CMSetAttachment (in-place!) anhaengen, PTS auf Host-Takt.
//   (4) %orig ganz am Ende: Die Anreicherung passiert VOR dem Originalpfad,
//       damit alle nachgelagerten Konsumenten den Frame MIT den Attachments
//       erhalten. (Wuerde man %orig zuerst rufen, haette der Original-Emit
//       den Buffer schon ohne Metadaten weitergereicht.)
//
// BWNodeOutput ist eine PRIVATE Klasse — Logos loest sie zur Laufzeit ueber
// den Klassen-Namen auf, es werden keine privaten Header benoetigt.
// ============================================================================

%hook BWNodeOutput

// Logos-Pitfall (geräte-verifiziert): opaque C-Pointer NICHT in die
// Hook-Signatur legen — der generierte Wrapper erwartet ein ObjC-`id`.
// Deshalb hier `id`, Bridge zu CMSampleBufferRef erst IM Body, und %orig
// bekommt exakt die `id`-Variable.
- (void)emitSampleBuffer:(id)sampleBuffer {
    if (sampleBuffer != nil) {
        CMSampleBufferRef sb = (__bridge CMSampleBufferRef)sampleBuffer;

        // (1) TypeGuard: nur echte SampleBuffer anfassen (der Graph ruft
        //     diese Methode nur mit CMSampleBufferRef auf, aber ein
        //     fehlerhafter Downstream-Tweak koennte den Parameter umbiegen).
        if (sb != NULL && CFGetTypeID(sb) == CMSampleBufferGetTypeID()) {

            // (2) Passthrough bei validen, bereits vorhandenen Metadaten.
            //     CMGetAttachment liest NUR den Attachments-Slot (keine
            //     Kopie, keine Allokation).
            CFTypeRef existingRef = CMGetAttachment(sb,
                                                    SF_METADATA_KEY,
                                                    NULL);
            NSDictionary *existing = (__bridge NSDictionary *)existingRef;

            if (!sf_metadata_is_valid(existing)) {

                // (3) Synthese + zerstörungsfreies Anhaengen am BESTEHENDEN
                //     Buffer. KEINE Reallokation, kein neuer CMSampleBufferRef,
                //     kein neuer CVPixelBufferRef — nur der Attachments-Slot
                //     wird gesetzt (kCMAttachmentMode_ShouldPropagate = 1,
                //     liest AVFoundation genauso zurueck).
                NSDictionary *exif = sf_build_exif();
                NSDictionary *meta = @{ SF_EXIF_DICT_KEY : exif };

                CMSetAttachment(sb,
                                SF_METADATA_KEY,
                                (__bridge CFTypeRef)meta,
                                kCMAttachmentMode_ShouldPropagate);

                // PTS nur im Simulationsfall anfassen (kein Eingriff in
                // echte, gesunde Feeds).
                sf_update_pts(sb);
            }
            // -> valide Metadaten: kompletter Passthrough, nichts passiert.
        }
    }

    // (4) Original-Emit mit dem (ggf. angereicherten) Buffer.
    %orig;
}

%end

// ============================================================================
// Konstruktor: RNG-Seed aus mach_absolute_time (Monotonic-High-Res-Takt,
// billiger als time(NULL) und nicht wall-clock-abhaengig).
// Hinweis zur Diagnose: os_log/NSLog wird in mediaserverd teils gefiltert —
// Geladen-Nachweis auf dem Geraet am besten host-seitig via syslog-Capture
// (idevicesyslog.exe) pruefen.
// ============================================================================
%ctor {
    uint32_t seed = (uint32_t)(mach_absolute_time() & 0xFFFFFFFFU);
    if (seed == 0) seed = 0x2545F491U;
    atomic_store_explicit(&sf_rng_state, seed | 1U, memory_order_relaxed);

    NSLog(@"[SensorForgePro] loaded in %@ — downstream metadata synth (iPhone 8 profile, passthrough bei validen Metadaten)",
          [[NSProcessInfo processInfo] processName]);
}
