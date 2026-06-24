DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 0.0.1

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppMute
AppMute_FILES = Tweak.x
AppMute_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
