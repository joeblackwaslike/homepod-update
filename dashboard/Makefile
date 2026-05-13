BINARY     := homepod-dashboard
REMOTE_DIR := /var/root
SSH_PORT   := 44

.PHONY: build deploy clean

build:
	GOOS=ios GOARCH=arm64 CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o $(BINARY) ./...

deploy: build
	scp -P $(SSH_PORT) $(BINARY) root@localhost:$(REMOTE_DIR)/$(BINARY)
	ssh root@localhost -p $(SSH_PORT) \
		"chmod +x $(REMOTE_DIR)/$(BINARY) && \
		 mkdir -p /var/mobile/Library/HomePodAudioBridge && \
		 killall $(BINARY) 2>/dev/null || true && \
		 $(REMOTE_DIR)/$(BINARY) &"
	@echo "Dashboard running at http://$$(ssh root@localhost -p $(SSH_PORT) 'ipconfig getifaddr en0'):8080"

clean:
	rm -f $(BINARY)
