TARGET  := iphone:clang:latest:12.0
ARCHS   := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HomePodAudioBridge

HomePodAudioBridge_FILES      = Tweak.x
HomePodAudioBridge_FRAMEWORKS = AudioToolbox CoreAudio CoreFoundation

include $(THEOS)/makefiles/tweak.mk

SSH_PORT   := 44
REMOTE_DIR := /var/root

deploy: package
	scp -P $(SSH_PORT) packages/*.deb root@localhost:$(REMOTE_DIR)/
	ssh root@localhost -p $(SSH_PORT) \
		"mount -o rw,update / && \
		 dpkg -i $(REMOTE_DIR)/*.deb && \
		 killall mediaserverd"
