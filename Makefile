# SensorForge Pro — Theos-Buildfile (roothide / rootless, iOS 16)
#
# Build lokal oder via GitHub Actions:
#   make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
#
# Kein Mac vorhanden -> GitHub Actions Workflow
#   .github/workflows/sensorforge-ios16.yml (waruhachi/theos-action @ roothide/Theos)

# Deployment-Target 14.0 deckt iOS 14-18 ab; arm64e braucht >= 13.0
# (13.0 + arm64e erzeugt Toolchain-Warnungen -> 14.0).
TARGET := iphone:clang:latest:14.0

# Universal-Binary: roothide-Packaging schreibt das .deb auf arm64e um,
# aber der arm64-Slice ist es, der auf dem A11 (iPhone 8) tatsaechlich laeuft.
# BEIDE Slices werden gebraucht.
ARCHS := arm64 arm64e

THEOS_PACKAGE_SCHEME := roothide

# Prozess, in dem injiziert wird (Filter-Plist macht den Rest).
INSTALL_TARGET_PROCESSES = mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SensorForgePro

SensorForgePro_FILES = Tweak.x
SensorForgePro_CFLAGS = -fobjc-arc
SensorForgePro_FRAMEWORKS = Foundation ImageIO CoreMedia CoreVideo
SensorForgePro_FILTER_FILES = Tweak.plist

include $(THEOS_MAKE_PATH)/tweak.mk
