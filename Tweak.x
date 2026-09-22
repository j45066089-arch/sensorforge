// ============================================================================
//  SensorForge Pro — Tweak.x  (v1.4)
// ----------------------------------------------------------------------------
//  Eigenstaendiger iOS-System-Tweak (mediaserverd, iOS 16.6-16.7.16, roothide).
//  ZWECK: Downstream-Metadaten-Synthese fuer emulierte Kamera-Feeds.
//
//  NEU IN v1.4 — ISP-Signatur (Forensik-grade Konsistenz):
//   * LuxLevel  = 250*F^2/(ISO*Exposure) — aus DEN WERTEN berechnet, die auch
//     in {Exif} landen. Lux/ISO/Exposure sind damit mathematisch konsistent
//     (Belichtungsgleichung, Kalibrierkonstante K=12.5 wie im echten AE).
//     Ein Frame ohne korreliertes Lux-Level "schreit PC-generiert".
//   * ispDGain (Tag 10): 256-basiert (256=1.0x), mit AGC gekoppelt — echte
//     iPhones fuehren IMMER einen ISP-Digital-Gain; fehlend = Fakenachweis.
//   * DigitalFlash (Tag 15) + focusPosition/LensPosition (Tag 13, Walk um
//     0.78) — Hinweise auf echte Hardware-Autofokus-Routine.
//   * MakerApple nutzt Apples NUMERISCHE MakerNote-Tags (wie echte iOS-16-
//     Frames), keine ausgedachten String-Keys:
//        1=LuxLevel, 2=AEStable, 3=AETarget, 4=AEAverage, 5=AFStable,
//        7=AFMode, 8=AGC, 9=DGain, 10=ispDGain, 13=focusPosition,
//        15=DigitalFlash.
//   * NEU: "keys?"-Kommando am Status-Port — dumpft die ECHTEN Key-Namen der
//     Apple-Metadaten von realen (passthrough-)Frames. Damit lässt sich das
//     hier synthetisierte Feld-Set 1:1 mit der echten Hardware vergleichen
//     und verfeinern — kein Raten.
//
//  Status-Port 8797: READ (Statuszeile) + WRITE (iso= exposure= fnumber=
//  lens= lux= flash= keys?).
//
//  UNVERAENDERTE SCHUTZREGELN: keine Reallokation (nur CMSetAttachment),
//  Passthrough bei validen Metadaten, Hook maximal downstream
//  (BWNodeOutput emitSampleBuffer:), PTS-Monotonie-Handling.
// ============================================================================

#import <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdint.h>
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
#define SF_METADATA_KEY       CFSTR(" MetadataDictionary")
#define SF_EXIF_DICT_KEY      @"{Exif}"

// --- iPhone-8-Defaultprofil -----------------------------------------------
#define SF_EXIF_LENS_MODEL    @"iPhone 8 Back Camera"
#define SF_EXIF_FNUMBER       (@1.8)
#define SF_ISO_BASE           200
#define SF_ISO_DELTA          5        // Pendelband => 195..205
#define SF_EXPOSURE_BASE_S    0.033    // 1/30 s

// --- Status-Port -----------------------------------------------------------
#define SF_STATUS_PORT        8797

// ----------------------------------------------------------------------------
// Fotometrische Konstanten: K = 12.5 (Kalibrierkonstante des klassischen
// Belichtungsmessers), C = 250 (Incident-Light-Konstante). LS /= ISOSpeed.
// Diese Zahl koppelt LuxLevel, ISO und Exposure — Kern der ISP-Korrelation.
// ----------------------------------------------------------------------------
#define SF_PHOTOMETRIC_C      250.0

// --- Konfiguration (Profil-Datei/Kommandoport ueberschreibbar) --------------
static _Atomic(double) g_cfgISO       = SF_ISO_BASE;
static _Atomic(double) g_cfgExposure  = SF_EXPOSURE_BASE_S;
static _Atomic(double) g_cfgFNumber   = 1.8;
static _Atomic(double) g_cfgLux       = 0.0;    // 0 = auto aus ISO/Exposure
static _Atomic(int)    g_cfgFlash     = 0;      // DigitalFlash-Override
static char            g_cfgLens[64];

// --- Random-Walk-State (v1.3/v1.4) -------------------------------------------
static _Atomic(double) g_walkISO       = SF_ISO_BASE;
static _Atomic(double) g_walkExposure  = SF_EXPOSURE_BASE_S;
static _Atomic(double) g_walkLensPos   = 0.78;  // Fokusposition 0..1
static _Atomic(int)    g_lastISO       = SF_ISO_BASE;
static _Atomic(double) g_lastExposure  = SF_EXPOSURE_BASE_S;
static _Atomic(double) g_lastLux       = 100.0;
static _Atomic(double) g_lastLensPos   = 0.78;

// --- Live-Zaehler ------------------------------------------------------------
static _Atomic(uint32_t) g_emitCount  = 0;
static _Atomic(uint32_t) g_synthCount = 0;
static _Atomic(uint32_t) g_passCount  = 0;
static _Atomic(uint32_t) g_ptsCount   = 0;

// --- Lese-Sonde --------------------------------------------------------------
static _Atomic(int) g_probeTxt       = -1;
static _Atomic(int) g_probeTxtErrno  = 0;
static _Atomic(int) g_probeJpg       = -1;
static _Atomic(int) g_probeJpgErrno  = 0;

// --- Key-Dump (keys? Kommando) -----------------------------------------------
// Rate-gebremster (max. 1x/s) Abgriff der ECHTEN Key-Namen der am Frame
// haengenden Dictionaries. Herkunft: dumpIsRaw=1 => vor unserer Synthese
// beobachtet (= Apple/original), 0 => bereits valide Metals (pass-Zweig).
static char            g_keydump[3072] = {0};
static _Atomic(time_t) g_lastDumpSec   = 0;
static _Atomic(int)    g_hasDump       = 0;
static _Atomic(int)    g_dumpIsRaw     = 0;
static _Atomic(int)    g_wantKeys      = 0;

// ----------------------------------------------------------------------------
// xorshift32-PRNG (sperrlos, Hot-Path-tauglich).
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
// Lese-Sonde: darf mediaserverd die Profil-Pfade oeffnen?
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
// Profil laden (Key=Value je Zeile).
// ----------------------------------------------------------------------------
static void sf_load_profile(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) return;
    char line[160];
    while (fgets(line, sizeof(line), f) != NULL) {
        char *eq = strchr(line, '=');
        if (eq == NULL) continue;
        *eq = '\0';
        char *val = eq + 1;
        val[strcspn(val, "\r\n")] = '\0';
        if (strcmp(line, "iso") == 0) {
            double d = atof(val);
            if (d >= 25.0 && d <= 6400.0)
                atomic_store_explicit(&g_cfgISO, d, memory_order_relaxed);
        } else if (strcmp(line, "exposure") == 0) {
            double d = atof(val);
            if (d > 0.0 && d <= 2.0)
                atomic_store_explicit(&g_cfgExposure, d, memory_order_relaxed);
        } else if (strcmp(line, "fnumber") == 0) {
            double d = atof(val);
            if (d >= 0.5 && d <= 32.0)
                atomic_store_explicit(&g_cfgFNumber, d, memory_order_relaxed);
        } else if (strcmp(line, "lux") == 0) {
            double d = atof(val);
            if (d >= 0.0 && d <= 250000.0)
                atomic_store_explicit(&g_cfgLux, d, memory_order_relaxed);
        } else if (strcmp(line, "lens") == 0) {
            snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", val);
        }
    }
    fclose(f);
}

// ----------------------------------------------------------------------------
// Key-Dump realer Apple-Frames (max. 1x/s) — Grundlage fuer den
// Forensik-Abgleich der MakerNote-Tags.
// ----------------------------------------------------------------------------
static void sf_maybe_dump_keys(NSDictionary *meta, int is_pass) {
    if (meta == nil || ![meta isKindOfClass:NSDictionary.class]) {
        if (!is_pass) {
            // synth-Zweig ohne vorhandene Metadaten: kurz dokumentieren.
            time_t now = time(NULL);
            time_t last = atomic_load_explicit(&g_lastDumpSec, memory_order_relaxed);
            if (now != last) {
                atomic_store_explicit(&g_lastDumpSec, now, memory_order_relaxed);
                snprintf(g_keydump, sizeof(g_keydump), "(kein MetadataDictionary vorhanden)");
                atomic_store_explicit(&g_hasDump, 1, memory_order_relaxed);
                atomic_store_explicit(&g_dumpIsRaw, 1, memory_order_relaxed);
            }
        }
        return;
    }
    time_t now = time(NULL);
    time_t last = atomic_load_explicit(&g_lastDumpSec, memory_order_relaxed);
    if (now == last) return;                       // Rate-Limit 1 Hz
    atomic_store_explicit(&g_lastDumpSec, now, memory_order_relaxed);

    NSMutableString *s = [NSMutableString string];
    NSDictionary *exif  = [meta objectForKey:SF_EXIF_DICT_KEY];
    NSDictionary *maker = [meta objectForKey:@"{MakerApple}"];
    if ([exif isKindOfClass:NSDictionary.class]) {
        [s appendString:@"exif:"];
        for (id k in [[exif allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [s appendFormat:@"%@;", k];
    }
    if ([maker isKindOfClass:NSDictionary.class]) {
        [s appendString:@" | maker:"];
        for (id k in [[maker allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [s appendFormat:@"%@;", k];
    }
    const char *utf8 = [s UTF8String];
    if (utf8 != NULL) {
        strncpy(g_keydump, utf8, sizeof(g_keydump) - 1);
        g_keydump[sizeof(g_keydump) - 1] = '\0';
        atomic_store_explicit(&g_hasDump, 1, memory_order_relaxed);
        atomic_store_explicit(&g_dumpIsRaw, !is_pass, memory_order_relaxed);
    }
}

// ----------------------------------------------------------------------------
// Status-Server: Loopback-TCP auf 8797.
//   READ-Seite: Statuszeile; mit Prefix "keys?" wird der Key-Dump geliefert.
//   WRITE-Seite: iso= exposure= fnumber= lens= lux= flash= (live uebernommen).
// ----------------------------------------------------------------------------
static void sf_handle_command(const char *cmd) {
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", cmd);

    if (strstr(buf, "keys?") != NULL) {
        atomic_store_explicit(&g_wantKeys, 1, memory_order_relaxed);
    }

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
        } else if (strcmp(tok, "lux") == 0) {
            double d = atof(val);
            if (d >= 0.0 && d <= 250000.0)
                atomic_store_explicit(&g_cfgLux, d, memory_order_relaxed);
        } else if (strcmp(tok, "flash") == 0) {
            atomic_store_explicit(&g_cfgFlash, atoi(val) ? 1 : 0,
                                  memory_order_relaxed);
        } else if (strcmp(tok, "lens") == 0) {
            snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", val);
        }
    }
}

static const char *sf_default_lens(void) {
    static const char defl[] = "iPhone 8 Back Camera";
    return defl;
}

static void sf_build_status_line(char *out, size_t outsz) {
    snprintf(out, outsz,
        "sforge=1 ver=1.6 "
        "emit=%u synth=%u pass=%u pts=%u "
        "probeTxt=%d(%d) probeJpg=%d(%d) "
        "cfgIso=%.0f cfgExposure=%.4f cfgFNumber=%.2f lens=%s "
        "walkIso=%d walkExposure=%.4f lux=%.1f lensPos=%.3f "
        "flash=%d dump=%d\n",
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
        atomic_load_explicit(&g_lastISO,      memory_order_relaxed),
        atomic_load_explicit(&g_lastExposure, memory_order_relaxed),
        atomic_load_explicit(&g_lastLux,      memory_order_relaxed),
        atomic_load_explicit(&g_lastLensPos,  memory_order_relaxed),
        atomic_load_explicit(&g_cfgFlash,     memory_order_relaxed),
        atomic_load_explicit(&g_hasDump,      memory_order_relaxed));
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

    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };

    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        char inbuf[256];
        ssize_t n = recv(c, inbuf, sizeof(inbuf) - 1, 0);
        if (n > 0) {
            inbuf[n] = '\0';
            sf_handle_command(inbuf);
        }

        char reply[3584];
        if (atomic_exchange_explicit(&g_wantKeys, 0, memory_order_relaxed)) {
            // Key-Dump liefern (forensischer Feld-Abgleich).
            int raw = atomic_load_explicit(&g_dumpIsRaw, memory_order_relaxed);
            snprintf(reply, sizeof(reply), "keys[%s]: %s\n",
                     raw ? "raw" : "valid",
                     (atomic_load_explicit(&g_hasDump, memory_order_relaxed)
                        ? g_keydump
                        : "(noch keine Frames beobachtet)"));
        } else {
            sf_build_status_line(reply, sizeof(reply));
        }
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
// Random-Walk (ISO, Exposure, LensPosition) mit Rueckstellkraft.
// ----------------------------------------------------------------------------
static int sf_walk_iso(void) {
    double cur  = atomic_load_explicit(&g_walkISO, memory_order_relaxed);
    double base = atomic_load_explicit(&g_cfgISO, memory_order_relaxed);

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

    double step = sf_rand_range(-0.0003, 0.0003) + (base - cur) * 0.03;
    cur += step;
    if (cur < base * 0.97) cur = base * 0.97;
    if (cur > base * 1.03) cur = base * 1.03;
    if (cur < 0.0005) cur = 0.0005;

    atomic_store_explicit(&g_walkExposure, cur, memory_order_relaxed);
    atomic_store_explicit(&g_lastExposure, cur, memory_order_relaxed);
    return cur;
}

// Fokusposition: iPhone-8-Rueckkamera ruht bei ~0.75-0.80 (Mitteldistanz),
// kleine kontinuierliche Schwankung wie eine echte AF-Routine.
static double sf_walk_lenspos(void) {
    double cur = atomic_load_explicit(&g_walkLensPos, memory_order_relaxed);
    double step = sf_rand_range(-0.004, 0.004) + (0.78 - cur) * 0.02;
    cur += step;
    if (cur < 0.60) cur = 0.60;
    if (cur > 0.90) cur = 0.90;
    atomic_store_explicit(&g_walkLensPos, cur, memory_order_relaxed);
    atomic_store_explicit(&g_lastLensPos, cur, memory_order_relaxed);
    return cur;
}

// ----------------------------------------------------------------------------
// LuxLevel — fotometrisch KORRELIERT mit ISO und Exposure:
//   Lux = C * F^2 / (ISO * t),  C = 250 (K=12.5).
// Damit erfüllt das Dict die Belichtungsgleichung — ein PC-generierter
// Frame fällt genau an diesem Check auf, wenn die Werte nicht zusammenpassen.
// lux=... am Port schaltet auf manuellen Lux (0 = auto).
// ----------------------------------------------------------------------------
static double sf_compute_lux(int iso, double exposure, double fnum) {
    double override = atomic_load_explicit(&g_cfgLux, memory_order_relaxed);
    double lux;
    if (override > 0.0) {
        lux = override;
    } else {
        lux = SF_PHOTOMETRIC_C * fnum * fnum /
              ((double)iso * (exposure > 0.0005 ? exposure : 0.0005));
    }
    // Kleines Messrauschen des ALS (Ambient Light Sensor).
    lux *= (1.0 + sf_rand_range(-0.015, 0.015));
    if (lux < 0.1) lux = 0.1;
    if (lux > 250000.0) lux = 250000.0;
    atomic_store_explicit(&g_lastLux, lux, memory_order_relaxed);
    return lux;
}

// ----------------------------------------------------------------------------
// ECHTE Apple-MakerNote-Tags (v1.5, Beleg: ExifTool-TagNames/Apple.html).
// Nummern-Schema hexadezimal, ein "14" ersetzt den (den Tweak verratenden)
// String-Namen 0x0001/MakerNoteVersion — wir nennen ihn bewusst NICHT.
//  0x0004 AEStable (0/1)         0x0005 AETarget
//  0x0006 AEAverage              0x0007 AFStable (0/1)
//  0x0008 AccelerationVector[3]  0x0014 ImageCaptureType (10=Photo)
//  0x0017 LivePhotoVideoIndex    0x001d LuminanceNoiseAmplitude
//  0x0027 SignalToNoiseRatio     0x002c DeviceUserDistance
//  0x002d ColorTemperature       0x002e CameraType (0=Back Wide Angle)
//  0x002f FocusPosition          0x0030 HDRGain
//  0x0038 AFMeasuredDepth        0x003d AFConfidence
//  0x003e ColorCorrectionMatrix
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_makernote(int iso, double exposure, double lux,
                                        double lensPos, double agc, int digFlash) {

    double snr = 3.0 + (agc - 1.0) * 1.6 + sf_rand_range(-0.2, 0.2); // Gain -> SNR faellt
    if (snr < 0.5) snr = 0.5;

    // Beschleunigungsvektor (0x0008): kleine, glaubwuerdige XY-Werte in g;
    // Z ~ 1.0 (Gravitation, Geraet steht aufrecht). Naturgetreu schwankend.
    double ax = sf_rand_range(-0.06, 0.06);
    double ay = sf_rand_range(-0.06, 0.06);
    double az = 0.98 + sf_rand_range(-0.03, 0.03);

    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:20];
    [m setObject:@14 forKey:@"1"];                                       // 0x0001 MakerNoteVersion
    [m setObject:@((sf_rand_u32() % 100) < 92 ? 1 : 0) forKey:@"4"];     // 0x0004 AEStable
    [m setObject:@((int)llround(lux * 0.8)) forKey:@"5"];                // 0x0005 AETarget
    [m setObject:@((int)sf_rand_range(110.0, 190.0)) forKey:@"6"];       // 0x0006 AEAverage
    [m setObject:@1 forKey:@"7"];                                        // 0x0007 AFStable
    [m setObject:@[@(ax), @(ay), @(az)] forKey:@"8"];                    // 0x0008 AccelerationVector
    [m setObject:@3 forKey:@"10"];                                       // 0x000a HDRImageType (3=HDR)
    [m setObject:@10 forKey:@"20"];                                      // 0x0014 ImageCaptureType=10
    [m setObject:@0 forKey:@"23"];                                       // 0x0017 LivePhotoVideoIndex
    [m setObject:@((double)sf_rand_range(0.20, 0.35)) forKey:@"29"];     // 0x001d LuminanceNoiseAmplitude
    [m setObject:@((double)sf_rand_range(1.5, 3.0)) forKey:@"33"];       // 0x0021 HDRHeadroom
    [m setObject:@[@((int)sf_rand_range(88, 100)),
                   @((int)sf_rand_range(88, 100))] forKey:@"35"];        // 0x0023 AFPerformance[2]
    [m setObject:@((int)sf_rand_range(0, 4)) forKey:@"37"];             // 0x0025 SceneFlags
    [m setObject:@1 forKey:@"38"];                                       // 0x0026 SignalToNoiseRatioType
    [m setObject:@(snr) forKey:@"39"];                                   // 0x0027 SignalToNoiseRatio
    [m setObject:@((int)sf_rand_range(55, 70)) forKey:@"44"];            // 0x002c DeviceUserDistance
    [m setObject:@((int)sf_rand_range(4700, 5200)) forKey:@"45"];        // 0x002d ColorTemperature
    [m setObject:@0 forKey:@"46"];                                       // 0x002e CameraType (Back Wide)
    [m setObject:@((int)llround(lensPos * 1000.0)) forKey:@"47"];        // 0x002f FocusPosition
    [m setObject:@(1.0 + sf_rand_range(-0.02, 0.02)) forKey:@"48"];      // 0x0030 HDRGain
    [m setObject:@((int)sf_rand_range(95, 125)) forKey:@"56"];           // 0x0038 AFMeasuredDepth
    [m setObject:@((int)sf_rand_range(70, 110)) forKey:@"61"];           // 0x003d AFConfidence
    return m;
}

// ----------------------------------------------------------------------------
// Video-Frame-Dictionary (v1.5): die STRING-Keys, die AVFoundation live am
// Frame liest. Das ist die "ISP-Signatur"-Schicht fuer Video — fehlen diese,
// weiss die Gegenseite sofort, dass der Frame nie durch eine Apple-ISP-
// Pipeline ging:
//   LuxLevel:         Umgebungslicht, muss mit ISO*Exposure korrelieren
//                     (Fotometrie: Lux = 250*F^2/(ISO*t))
//   ispDGain:         ISP-Digital-Gain (256-basiert). IMMER vorhanden.
//   DigitalFlash:     kurzer Hardware-Flash-Indikator
//   LensPosition:     Fokustrieb 0..1 — "mikroskopischer" AF-Beweis
//   FocusConfidence, FocusMode, snr, luma ve_runden das Bild ab.
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_videometa(int iso, double exposure, double lux,
                                        double lensPos, double agc, int digFlash) {
    int ispdg = 256 + (int)llround((agc - 1.0) * 220.0);
    if (ispdg < 256) ispdg = 256;
    if (ispdg > 2048) ispdg = 2048;
    ispdg += (int)sf_rand_range(-4.0, 5.0);

    NSMutableDictionary *v = [NSMutableDictionary dictionaryWithCapacity:8];
    [v setObject:@((double)llround(lux * 100.0) / 100.0)  forKey:@"LuxLevel"];
    [v setObject:@(ispdg)                                 forKey:@"ispDGain"];
    [v setObject:@(digFlash)                              forKey:@"DigitalFlash"];
    [v setObject:@(lensPos)                               forKey:@"LensPosition"];
    [v setObject:@((int)sf_rand_range(70, 110))           forKey:@"FocusConfidence"];
    [v setObject:@((int)sf_rand_range(60, 110))           forKey:@"FocusDistance"];
    [v setObject:@(agc)                                   forKey:@"AGC"];
    [v setObject:@(1.0 + sf_rand_range(-0.05, 0.05))      forKey:@"DGain"];
    return v;
}

// ----------------------------------------------------------------------------
// Gesamt-Metadata (v1.5): {Exif} + {MakerApple} + Video-String-Keys.
// ----------------------------------------------------------------------------
static NSDictionary *sf_build_meta(void) {
    double fnum     = atomic_load_explicit(&g_cfgFNumber, memory_order_relaxed);
    int    iso      = sf_walk_iso();
    double exposure = sf_walk_exposure();
    double lensPos  = sf_walk_lenspos();
    double lux      = sf_compute_lux(iso, exposure, fnum);
    double agc      = SF_EXPOSURE_BASE_S / (exposure > 0.0005 ? exposure : 0.0005);
    int    digFlash = atomic_load_explicit(&g_cfgFlash, memory_order_relaxed) ? 1 : 0;

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

    NSDictionary *maker     = sf_build_makernote(iso, exposure, lux, lensPos, agc, digFlash);
    NSDictionary *videometa = sf_build_videometa(iso, exposure, lux, lensPos, agc, digFlash);

    NSMutableDictionary *meta = [NSMutableDictionary dictionaryWithCapacity:8];
    [meta setObject:exif      forKey:SF_EXIF_DICT_KEY];
    [meta setObject:maker     forKey:@"{MakerApple}"];
    [meta addEntriesFromDictionary:videometa];
    return meta;
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
                // valide Metals beobachten (kann auch unser kreisender
                // Synth-Frame sein -> dumpIsRaw=0).
                sf_maybe_dump_keys(existing, 1);
            } else {
                // VOR der Synthese abgreifen, was (ggf. partiell) am Frame
                // haengt: DAS ist die echte Apple/Original-Signatur.
                sf_maybe_dump_keys(existing, 0);
                // Synthese: {Exif} + {MakerApple} + Video-String-Keys.
                NSDictionary *meta = sf_build_meta();

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
// %ctor
// ============================================================================
%ctor {
    uint32_t seed = (uint32_t)(mach_absolute_time() & 0xFFFFFFFFU);
    if (seed == 0) seed = 0x2545F491U;
    atomic_store_explicit(&sf_rng_state, seed | 1U, memory_order_relaxed);

    snprintf(g_cfgLens, sizeof(g_cfgLens), "%s", "");

    // Lese-Sonde.
    sf_probe_path("/var/mobile/Documents/sensorforge_profile.txt",
                  &g_probeTxt, &g_probeTxtErrno);
    sf_probe_path("/var/mobile/Documents/sensorforge_profile.jpg",
                  &g_probeJpg, &g_probeJpgErrno);

    // Profil laden (falls lesbar) — ueberschreibt die Defaults.
    sf_load_profile("/var/mobile/Documents/sensorforge_profile.txt");

    // Status-Server auf Utility-Queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sf_status_runloop();
    });

    NSLog(@"[SensorForgePro] v1.4 loaded in %@ — ISP-Signatur (Lux/ispDGain/DigitalFlash/LensPos) + keys?-Abgleich",
          [[NSProcessInfo processInfo] processName]);
}
