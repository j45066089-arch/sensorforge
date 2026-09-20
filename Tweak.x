// ============================================================================
//  SensorForge Pro — Tweak.x  (v1.1)
// ----------------------------------------------------------------------------
//  Eigenstaendiger iOS-System-Tweak (mediaserverd, iOS 16.6-16.7.16, roothide).
//  ZWECK: Downstream-Metadaten-Synthese fuer emulierte Kamera-Feeds.
//
//  NEU IN v1.1:
//   * Status-Port 8797 (Loopback-TCP, sandbox-freundlich) mit Live-Zaehlern
//     (emit/synth/pass/pts) — dieser Port BELEGT die Injektion, da NSLog in
//     mediaserverd gefiltert wird.
//   * Datei-Lese-Sonde im %ctor: try open() auf die Profil-Pfade und meldet
//     am Status-Port probeTxt/JPG + errno. Damit messen wir, ob der
//     sandboxed Daemon die Profil-Datei ueberhaupt LESEN darf.
//   * Profil-Datei-Support (fallback auf iPhone-8-Defaults):
//       /var/mobile/Documents/sensorforge_profile.txt
//       Zeilenformat:  iso=200
//                      exposure=0.033
//                      fnumber=1.8
//                      lens=iPhone 8 Back Camera
//     Werte ueberschreiben die Basiswerte der Synthese (die dynamische
//     Fluktuation bleibt erhalten). Damit laesst sich die Ausgabe eines
//     Host-Rechners/Webservers direkt per Datei einspeisen — sofern die
//     Sandbox-Sonde Leserechte bestaetigt.
//
//  UNVERAENDERTE SCHUTZREGELN: keine Reallokation (nur CMSetAttachment),
//  Passthrough bei validen Metadaten, Hook maximal downstream
//  (BWNodeOutput emitSampleBuffer:).
// ============================================================================

#import <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>

// --- Attachment-Key ---------------------------------------------------------
// Exakter CoreMedia-Wert des MetadataDictionary-Keys (fuehrendes Leerzeichen
// ist kein Tippfehler): kCMSampleBufferAttachmentKey_MetadataDictionary
// = CFSTR(" MetadataDictionary").
#define SF_METADATA_KEY       CFSTR(" MetadataDictionary")
#define SF_EXIF_DICT_KEY      @"{Exif}"

// --- iPhone-8-Defaultprofil (gilt, solange keine Profil-Datei da ist) ------
#define SF_EXIF_LENS_MODEL    @"iPhone 8 Back Camera"
#define SF_EXIF_FNUMBER       (@1.8)
#define SF_ISO_BASE           200
#define SF_ISO_DELTA          5        // Pendelband => 195..205
#define SF_EXPOSURE_BASE_S    0.033    // 1/30 s
#define SF_EXPOSURE_JITTER_S  0.0006

// --- Status-Port -----------------------------------------------------------
#define SF_STATUS_PORT        8797

// --- Konfiguration (von der Profil-Datei/Kommandoport ueberschreibbar) ------
static _Atomic(double) g_cfgISO       = SF_ISO_BASE;
static _Atomic(double) g_cfgExposure  = SF_EXPOSURE_BASE_S;
static _Atomic(double) g_cfgFNumber   = 1.8;
static char            g_cfgLens[64]; // einmalig im %ctor geschrieben

// --- Random-Walk-State (v1.3): statt reinem Jitter ein zeitabhaengiger Walk
//     mit Rueckstellkraft zur Basis — so pendelt der "Sensor" wie ein echter
//     AEC-Loop um den Arbeitspunkt.
static _Atomic(double) g_walkISO      = SF_ISO_BASE;
static _Atomic(double) g_walkExposure = SF_EXPOSURE_BASE_S;
// Letzte publizierte Werte (Statuszeile => Walk sichtbar).
static _Atomic(int)    g_lastISO      = SF_ISO_BASE;
static _Atomic(double) g_lastExposure = SF_EXPOSURE_BASE_S;

// --- Live-Zaehler (Status-Port) ---------------------------------------------
static _Atomic(uint32_t) g_emitCount  = 0;  // Hook-Aufrufe gesamt (Injektionsbeweis)
static _Atomic(uint32_t) g_synthCount = 0;  // simulierte Frames
static _Atomic(uint32_t) g_passCount  = 0;  // Passthrough (valide Metadaten)
static _Atomic(uint32_t) g_ptsCount   = 0;  // PTS-Updates

// --- Lese-Sonde (Ergebnisse fuer den Status-Port) ---------------------------
static _Atomic(int) g_probeTxt   = -1;   // 1=lesbar, 0=fehlgeschlagen
static _Atomic(int) g_probeTxtErrno = 0;
static _Atomic(int) g_probeJpg   = -1;
static _Atomic(int) g_probeJpgErrno = 0;
static _Atomic(int) g_probeVartmp = -1;
static _Atomic(int) g_probeVartmpErrno = 0;

// ----------------------------------------------------------------------------
// xorshift32-PRNG (sperrlos, Hot-Path-tauglich; kein libc-rand-Locking).
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

static double sf_rand_range(double lo, double hi) {
    double unit = (double)sf_rand_u32() / 4294967296.0;
    return lo + unit * (hi - lo);
}

// ----------------------------------------------------------------------------
// Lese-Sonde: darf mediaserverd die Profil-Pfade oeffnen? Ergebnis nur
// diagnostisch (open + read, kein write).
// ----------------------------------------------------------------------------
static void sf_probe_path(const char *path, _Atomic(int) *result,
                          _Atomic(int) *err) {
    if (path == NULL) return;
    int fd = open(path, O_RDONLY);
    atomic_store_explicit(result, fd >= 0 ? 1 : 0, memory_order_relaxed);
    atomic_store_explicit(err, fd >= 0 ? 0 : errno, memory_order_relaxed);
    if (fd >= 0) close(fd);
}

// ----------------------------------------------------------------------------
// Profil laden: einfaches Zeilenformat key=value. Fehlen Zeilen oder die
// Datei, bleiben die iPhone-8-Defaults aktiv.
// ----------------------------------------------------------------------------
static void sf_load_profile(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) return;
    char line[160];
    while (fgets(line, sizeof(line), f) != NULL) {
        char *eq = strchr(line, '=');
        if (eq == NULL) continue;
        *eq = '\0';
        char *key = line;
        // trailing \n/\r entfernen
        char *val = eq + 1;
        val[strcspn(val, "\r\n")] = '\0';

        if (strcmp(key, "iso") == 0) {
            double d = atof(val);
            if (d >= 25.0 && d <= 6400.0)
                atomic_store_explicit(&g_cfgISO, d, memory_order_relaxed);
        } else if (strcmp(key, "exposure") == 0) {
            double d = atof(val);
            if (d > 0.0 && d <= 2.0)
                atomic_store_explicit(&g_cfgExposure, d, memory_order_relaxed);
        } else if (strcmp(key, "fnumber") == 0) {
            double d = atof(val);
            if (d >= 0.5 && d <= 32.0)
                atomic_store_explicit(&g_cfgFNumber, d, memory_order_relaxed);
        } else if (strcmp(key, "lens") == 0) {
            snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", val);
        }
    }
    fclose(f);
}

// ----------------------------------------------------------------------------
// Status-Server: Loopback-TCP auf 8797. Zwei Funktionen:
//   * READ-Seite: jede Verbindung liefert sofort eine Statuszeile.
//   * WRITE-Seite (v1.2): eintreffende Kommandos  iso=320  exposure=0.02
//     fnumber=2.2  lens=Linsenname  werden geparst und live uebernommen.
//     So speist ein Host-Prozess (PC-Tool, SpringBoard-Hub) die aus einem
//     Bild/Video berechneten EXIF-Werte direkt in den Daemon — der einzige
//     Kanal, der die mediaserverd-Sandbox-Pfadsicht umgeht (Datei-Read
//     endet hier mit errno 2/ENOENT, siehe %ctor-Sonde).
// ----------------------------------------------------------------------------
static void sf_handle_command(const char *cmd) {
    // Puffer-Kopie: sicher gegen nicht-terminierte Recv-Brocken.
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", cmd);

    // Mehrere Kommandos je Zeile, getrennt durch Leerzeichen.
    char *save = NULL;
    for (char *tok = strtok_r(buf, " \t\r\n,", &save);
         tok != NULL;
         tok = strtok_r(NULL, " \t\r\n,", &save)) {

        char *eq = strchr(tok, '=');
        if (eq == NULL) continue;
        *eq = '\0';
        const char *val = eq + 1;

        if (strcmp(tok, "iso") == 0) {
            double d = atof(val);
            if (d >= 25.0 && d <= 6400.0)
                atomic_store_explicit(&g_cfgISO, d, memory_order_relaxed);
        } else if (strcmp(tok, "exposure") == 0) {
            double d = atof(val);
            if (d > 0.0 && d <= 2.0)
                atomic_store_explicit(&g_cfgExposure, d, memory_order_relaxed);
        } else if (strcmp(tok, "fnumber") == 0) {
            double d = atof(val);
            if (d >= 0.5 && d <= 32.0)
                atomic_store_explicit(&g_cfgFNumber, d, memory_order_relaxed);
        } else if (strcmp(tok, "lens") == 0) {
            snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", val);
        }
    }
}

// Fallback-Lenslabel als C-String (sf_build_status_line lebt im C-Kontext).
static const char *sf_default_lens(void) {
    static const char defl[] = "iPhone 8 Back Camera";
    return defl;
}

static void sf_build_status_line(char *out, size_t outsz) {
    snprintf(out, outsz,
        "sforge=1 ver=1.3 "
        "emit=%u synth=%u pass=%u pts=%u "
        "probeTxt=%d(%d) probeJpg=%d(%d) "
        "cfgIso=%.0f cfgExposure=%.4f cfgFNumber=%.2f lens=%s "
        "walkIso=%d walkExposure=%.4f\n",
        (unsigned)atomic_load_explicit(&g_emitCount,  memory_order_relaxed),
        (unsigned)atomic_load_explicit(&g_synthCount, memory_order_relaxed),
        (unsigned)atomic_load_explicit(&g_passCount,  memory_order_relaxed),
        (unsigned)atomic_load_explicit(&g_ptsCount,   memory_order_relaxed),
        atomic_load_explicit(&g_probeTxt,   memory_order_relaxed),
        atomic_load_explicit(&g_probeTxtErrno, memory_order_relaxed),
        atomic_load_explicit(&g_probeJpg,   memory_order_relaxed),
        atomic_load_explicit(&g_probeJpgErrno, memory_order_relaxed),
        atomic_load_explicit(&g_cfgISO,      memory_order_relaxed),
        atomic_load_explicit(&g_cfgExposure, memory_order_relaxed),
        atomic_load_explicit(&g_cfgFNumber,  memory_order_relaxed),
        g_cfgLens[0] != '\0' ? g_cfgLens : sf_default_lens(),
        atomic_load_explicit(&g_lastISO,     memory_order_relaxed),
        atomic_load_explicit(&g_lastExposure, memory_order_relaxed));
}

static void sf_status_runloop(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons(SF_STATUS_PORT);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(srv);
        return;  // Port belegt? (z. B. doppelte Ladung) -> still aufgeben
    }
    if (listen(srv, 4) != 0) { close(srv); return; }

    // recv-Timeout, damit accept-Schleife nicht haengt.
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };

    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // 1) Eingehende Kommandos einlesen (falls der Client welche sendet).
        char inbuf[256];
        ssize_t n = recv(c, inbuf, sizeof(inbuf) - 1, 0);
        if (n > 0) {
            inbuf[n] = '\0';
            sf_handle_command(inbuf);
        }

        // 2) Immer die volle Statuszeile zurueckgeben (Poll-Modus).
        char reply[512];
        sf_build_status_line(reply, sizeof(reply));
        (void)send(c, reply, strlen(reply), 0);
        close(c);
    }
}

// ----------------------------------------------------------------------------
// Validity-Check: Dictionary gilt als valide, wenn "{Exif}".FNumber oder
// .ISOSpeedRatings existiert => Passthrough.
// ----------------------------------------------------------------------------
static BOOL sf_metadata_is_valid(NSDictionary *existing) {
    if (existing == nil || ![existing isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *exif = [existing objectForKey:SF_EXIF_DICT_KEY];
    if (exif == nil || ![exif isKindOfClass:NSDictionary.class]) return NO;
    if ([exif objectForKey:(NSString *)kCGImagePropertyExifFNumber] != nil) return YES;
    if ([exif objectForKey:(NSString *)kCGImagePropertyExifISOSpeedRatings] != nil) return YES;
    return NO;
}

// EXIF-Zeitstempel ohne NSDateFormatter (Hot-Path-tauglich).
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
// Random-Walk (v1.3): kleiner Schritt pro Aufruf + schwache Rueckstellkraft
// zum Arbeitspunkt. Deckel = das Pendelband des Profils, damit der Wert nie
// ausreist. Ergebnis: natuerliche AEC-artige Fluktuation statt weissen
// Rauschens.
// ----------------------------------------------------------------------------
static int sf_walk_iso(void) {
    double cur  = atomic_load_explicit(&g_walkISO, memory_order_relaxed);
    double base = atomic_load_explicit(&g_cfgISO, memory_order_relaxed);

    // Schritt: 0..1.5 ISO pro Frame-Zyklus + 3% Rueckstellkraft zur Mitte.
    double step = sf_rand_range(-1.5, 1.5) + (base - cur) * 0.03;
    cur += step;
    if (cur < base - SF_ISO_DELTA) cur = base - SF_ISO_DELTA;
    if (cur > base + SF_ISO_DELTA) cur = base + SF_ISO_DELTA;

    atomic_store_explicit(&g_walkISO, cur, memory_order_relaxed);
    int iso = (int)llround(cur);
    if (iso < 25) iso = 25;
    atomic_store_explicit(&g_lastISO, iso, memory_order_relaxed);
    return iso;
}

static double sf_walk_exposure(void) {
    double cur  = atomic_load_explicit(&g_walkExposure, memory_order_relaxed);
    double base = atomic_load_explicit(&g_cfgExposure, memory_order_relaxed);

    // Schritt in Sekunden: ~+-0.3 ms + Rueckstellkraft; Deckel +-3%.
    double step = sf_rand_range(-0.0003, 0.0003) + (base - cur) * 0.03;
    cur += step;
    if (cur < base * 0.97) cur = base * 0.97;
    if (cur > base * 1.03) cur = base * 1.03;
    if (cur < 0.0005) cur = 0.0005;

    atomic_store_explicit(&g_walkExposure, cur, memory_order_relaxed);
    atomic_store_explicit(&g_lastExposure, cur, memory_order_relaxed);
    return cur;
}

// ----------------------------------------------------------------------------
// MakerApple-Synthese (v1.3): Apple-typische Sensorfelder, die moderne Apps
// und EXIF-Tools neben "{Exif}" erwarten. Klein und plausibel gehalten;
// echte Frames fuehren ~34 Felder — die hier genannten sind die haeufig
// geprueften (AEStable/AFStable/AEAverage/AGC/DGain).
// Analog-Gain (AGC) aus dem Belichtungsverhaeltnis zur 1/30-s-Norm.
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_maker(double exposure) {
    NSMutableDictionary *maker = [NSMutableDictionary dictionaryWithCapacity:6];

    // ueberwiegend stabil, selten kurzer Sprung (AEC reagiert).
    [maker setObject:@((sf_rand_u32() % 100) < 92 ? 1 : 0)
              forKey:@"AEStable"];
    [maker setObject:@1
              forKey:@"AFStable"];
    [maker setObject:@((int)sf_rand_range(110, 190))
              forKey:@"AEAverage"];
    [maker setObject:@((int)sf_rand_range(70, 110))
              forKey:@"AFConfidence"];
    [maker setObject:@(SF_EXPOSURE_BASE_S / (exposure > 0.0005 ? exposure : 0.0005))
              forKey:@"AGC"];
    [maker setObject:@((double)1.0 + sf_rand_range(-0.05, 0.05))
              forKey:@"DGain"];
    return maker;
}

// ----------------------------------------------------------------------------
// EXIF-Synthese: Basiswerte aus Profil-Datei (falls gelesen) sonst
// iPhone-8-Defaults; darueber der Random-Walk (dynamische Sensorfluktuation).
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_exif(void) {
    double fnum     = atomic_load_explicit(&g_cfgFNumber, memory_order_relaxed);

    int iso         = sf_walk_iso();
    double exposure = sf_walk_exposure();

    NSMutableDictionary *exif = [NSMutableDictionary dictionaryWithCapacity:5];
    [exif setObject:@(fnum)
             forKey:(NSString *)kCGImagePropertyExifFNumber];
    [exif setObject:((g_cfgLens[0] != '\0')
                        ? [NSString stringWithUTF8String:g_cfgLens]
                        : SF_EXIF_LENS_MODEL)
             forKey:(NSString *)kCGImagePropertyExifLensModel];
    [exif setObject:@[ @(iso) ]
             forKey:(NSString *)kCGImagePropertyExifISOSpeedRatings];
    [exif setObject:@(exposure)
             forKey:(NSString *)kCGImagePropertyExifExposureTime];
    [exif setObject:sf_exif_timestamp()
             forKey:(NSString *)kCGImagePropertyExifDateTimeOriginal];
    return exif;
}

// ----------------------------------------------------------------------------
// PTS in-place auf Host-Takt setzen (monoton nach vorne).
// ----------------------------------------------------------------------------
static void sf_update_pts(CMSampleBufferRef buf) {
    if (buf == NULL) return;
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTime oldPts   = CMSampleBufferGetOutputPresentationTimeStamp(buf);
    CMTime newPts   = hostTime;
    if (CMTIME_IS_VALID(oldPts) && CMTimeCompare(hostTime, oldPts) < 0) {
        newPts = CMTimeAdd(oldPts, CMTimeMakeWithSeconds(0.0001, 1000000));
    }
    if (CMTIME_IS_VALID(newPts)) {
        CMSampleBufferSetOutputPresentationTimeStamp(buf, newPts);
        atomic_fetch_add_explicit(&g_ptsCount, 1, memory_order_relaxed);
    }
}

// ============================================================================
// HOOK — maximale Downstream-Stufe (BWNodeOutput emitSampleBuffer:).
// Logos-Pitfall: id in der Signatur, CMSampleBufferRef erst im Body.
// ============================================================================
%hook BWNodeOutput

- (void)emitSampleBuffer:(id)sampleBuffer {
    atomic_fetch_add_explicit(&g_emitCount, 1, memory_order_relaxed);

    if (sampleBuffer != nil) {
        CMSampleBufferRef sb = (__bridge CMSampleBufferRef)sampleBuffer;
        if (sb != NULL && CFGetTypeID(sb) == CMSampleBufferGetTypeID()) {

            CFTypeRef existingRef = CMGetAttachment(sb, SF_METADATA_KEY, NULL);
            NSDictionary *existing = (__bridge NSDictionary *)existingRef;

            if (sf_metadata_is_valid(existing)) {
                atomic_fetch_add_explicit(&g_passCount, 1, memory_order_relaxed);
            } else {
                // Synthese: {Exif} + {MakerApple} in EINEM Dictionary.
                // CMSetAttachment erfolgt unmittelbar hier — also direkt
                // nachdem der (ggf. durch einen Frame-Swap-Tweak ersetzte)
                // Buffer durchreicht. Kein neuer Buffer, nur Attachments.
                NSDictionary *exif  = sf_build_exif();
                double exposure =
                    (double)atomic_load_explicit(&g_lastExposure, memory_order_relaxed);
                if (exposure < 0.0005) exposure = 0.0005;
                NSDictionary *maker = sf_build_maker(exposure);
                NSDictionary *meta = @{ SF_EXIF_DICT_KEY : exif,
                                        @"{MakerApple}"    : maker };

                CMSetAttachment(sb, SF_METADATA_KEY,
                                (__bridge CFTypeRef)meta,
                                kCMAttachmentMode_ShouldPropagate);
                sf_update_pts(sb);
                atomic_fetch_add_explicit(&g_synthCount, 1, memory_order_relaxed);
            }
        }
    }
    %orig;
}

%end

// ============================================================================
// %ctor: Defaults setzen, Lese-Sonde starten, Profil laden, Status-Server
// starten. Reihenfolge bewusst: erst Sonde+Profil (einmalig), dann Server.
// ============================================================================
%ctor {
    uint32_t seed = (uint32_t)(mach_absolute_time() & 0xFFFFFFFFU);
    if (seed == 0) seed = 0x2545F491U;
    atomic_store_explicit(&sf_rng_state, seed | 1U, memory_order_relaxed);

    snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", "");

    // Lese-Sonde: vorhandene Dateien? Sonde misst Lesbarkeit in mediaserverd.
    sf_probe_path("/var/mobile/Documents/sensorforge_profile.txt",
                  &g_probeTxt, &g_probeTxtErrno);
    sf_probe_path("/var/mobile/Documents/sensorforge_profile.jpg",
                  &g_probeJpg, &g_probeJpgErrno);
    sf_probe_path("/var/tmp/sensorforge_profile.txt",
                  &g_probeVartmp, &g_probeVartmpErrno);

    // Profil laden (falls lesbar) — ueberschreibt die Defaults.
    sf_load_profile("/var/mobile/Documents/sensorforge_profile.txt");

    // Status-Server auf Utility-Queue (blockiert nie den Hauptpfad).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sf_status_runloop();
    });

    NSLog(@"[SensorForgePro] v1.3 loaded in %@ — status port %d (read+commands, Exif+MakerApple, random-walk)",
          [[NSProcessInfo processInfo] processName], SF_STATUS_PORT);
}
