# homepod-update

Repurposes a jailbroken 1st-gen HomePod (audioOS / A8) into a bidirectional voice satellite
for Home Assistant or an OpenClaw cluster.

## Architecture

- **tweak/** — Theos/MobileSubstrate tweak that hooks `mediaserverd`, captures beam-formed mic
  audio, and streams it to a central server via Wyoming protocol over TCP
- **dashboard/** — Go HTTP server providing a live web UI for configuration, logs, uptime, and
  error monitoring. Runs on the HomePod at port 8080.
- **docs/** — Full technical blueprint

## Quick start

### 1. Jailbreak

Follow `docs/blueprint.md` §2 — pogo-pin dock + checkra1n on the A8.

### 2. Deploy the tweak

```bash
cd tweak
# Edit Makefile: set THEOS path
make package
make deploy   # scps + installs over iproxy tunnel
```

### 3. Deploy the dashboard

```bash
cd dashboard
make deploy   # cross-compiles for arm64 iOS, scps, starts on device
# → http://<homepod-ip>:8080
```

### 4. Configure

Set your HA hostname and port either via the dashboard UI or by editing the plist directly:

```
/var/mobile/Library/Preferences/com.yourname.homepodaudiobridge.plist
```

## Requirements

- Mac with Xcode CLT
- [Theos](https://theos.dev) installed at `~/theos`
- Go 1.22+
- `iproxy` (`brew install libimobiledevice`)
- `gh` CLI for repo management

## References

- [UnbendableStraw/homepwn-simple](https://github.com/UnbendableStraw/homepwn-simple) — pogo-pin dock STLs and pinout
- [checkra1n](https://checkra.in) — A8 jailbreak via checkm8 bootrom exploit
- [Wyoming protocol](https://github.com/rhasspy/wyoming) — Home Assistant voice satellite protocol
