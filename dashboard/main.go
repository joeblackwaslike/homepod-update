package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"howett.me/plist"
)

//go:embed static/index.html
var indexHTML []byte

const (
	configPath = "/var/mobile/Library/Preferences/com.yourname.homepodaudiobridge.plist"
	statusPath = "/var/mobile/Library/HomePodAudioBridge/status.json"
	logPath    = "/var/mobile/Library/HomePodAudioBridge/bridge.log"
	listenAddr = ":8080"
)

// Config mirrors the plist schema read and written by the tweak.
type Config struct {
	ServerIP      string `plist:"ServerIP"        json:"server_ip"`
	ServerPort    int    `plist:"ServerPort"      json:"server_port"`
	RetryInterval int    `plist:"RetryInterval"   json:"retry_interval"`
	SampleRate    int    `plist:"AudioSampleRate" json:"sample_rate"`
	Channels      int    `plist:"AudioChannels"   json:"channels"`
	BitWidth      int    `plist:"AudioBitWidth"   json:"bit_width"`
	SOKeepAlive   bool   `plist:"SOKeepAlive"     json:"so_keepalive"`
	AutoRestart   bool   `plist:"AutoRestart"     json:"auto_restart"`
}

// TweakStatus is written periodically by the tweak to statusPath.
type TweakStatus struct {
	Connected      bool   `json:"connected"`
	ServerIP       string `json:"server_ip"`
	ServerPort     int    `json:"server_port"`
	ChunksSent     int64  `json:"chunks_sent"`
	Reconnects     int    `json:"reconnects"`
	SendErrors     int    `json:"send_errors"`
	ConnectedSince int64  `json:"connected_since"`
	LastUpdated    int64  `json:"last_updated"`
	AsbdRate       int    `json:"asbd_rate"`
	AsbdChannels   int    `json:"asbd_channels"`
	AsbdWidth      int    `json:"asbd_width"`
}

// StatusResponse extends TweakStatus with server-computed fields.
type StatusResponse struct {
	TweakStatus
	SystemUptimeSeconds int64  `json:"system_uptime_seconds"`
	BridgeUptimeSeconds int64  `json:"bridge_uptime_seconds"`
	DeviceIP            string `json:"device_ip"`
}

// LogLine is a parsed entry from bridge.log.
type LogLine struct {
	Time    string `json:"time"`
	Level   string `json:"level"`
	Message string `json:"message"`
}

func systemUptime() time.Duration {
	tv, err := syscall.SysctlTimeval("kern.boottime")
	if err != nil {
		return 0
	}
	boot := time.Unix(tv.Sec, int64(tv.Usec)*1000)
	return time.Since(boot)
}

func deviceIP() string {
	out, err := exec.Command("ipconfig", "getifaddr", "en0").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

func readConfig() (*Config, error) {
	f, err := os.Open(configPath)
	if err != nil {
		return nil, fmt.Errorf("open config: %w", err)
	}
	defer f.Close()
	var cfg Config
	if err := plist.NewDecoder(f).Decode(&cfg); err != nil {
		return nil, fmt.Errorf("decode plist: %w", err)
	}
	return &cfg, nil
}

func writeConfig(cfg *Config) error {
	f, err := os.Create(configPath)
	if err != nil {
		return fmt.Errorf("create config: %w", err)
	}
	defer f.Close()
	enc := plist.NewEncoder(f)
	enc.Indent("\t")
	return enc.Encode(cfg)
}

func readTweakStatus() (*TweakStatus, error) {
	data, err := os.ReadFile(statusPath)
	if err != nil {
		return nil, fmt.Errorf("read status: %w", err)
	}
	var s TweakStatus
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parse status: %w", err)
	}
	return &s, nil
}

func tailLog(n int, level, filter string) ([]LogLine, error) {
	out, err := exec.Command("tail", "-n", strconv.Itoa(n), logPath).Output()
	if err != nil {
		return nil, fmt.Errorf("tail log: %w", err)
	}
	var lines []LogLine
	for _, raw := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if raw == "" {
			continue
		}
		ll := parseLine(raw)
		if level != "" && ll.Level != level {
			continue
		}
		if filter != "" && !strings.Contains(strings.ToLower(ll.Message), strings.ToLower(filter)) {
			continue
		}
		lines = append(lines, ll)
	}
	return lines, nil
}

func parseLine(raw string) LogLine {
	parts := strings.SplitN(raw, " ", 3)
	if len(parts) < 3 {
		return LogLine{Time: "", Level: "info", Message: raw}
	}
	return LogLine{
		Time:    parts[0],
		Level:   strings.ToLower(strings.Trim(parts[1], "[]")),
		Message: parts[2],
	}
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(indexHTML)
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	ts, err := readTweakStatus()
	if err != nil {
		ts = &TweakStatus{}
	}
	uptime := systemUptime()
	var bridgeUptime int64
	if ts.ConnectedSince > 0 {
		bridgeUptime = time.Now().Unix() - ts.ConnectedSince
	}
	resp := StatusResponse{
		TweakStatus:         *ts,
		SystemUptimeSeconds: int64(uptime.Seconds()),
		BridgeUptimeSeconds: bridgeUptime,
		DeviceIP:            deviceIP(),
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func handleLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	n, _ := strconv.Atoi(q.Get("n"))
	if n <= 0 {
		n = 150
	}
	lines, err := tailLog(n, strings.ToLower(q.Get("level")), q.Get("filter"))
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if lines == nil {
		lines = []LogLine{}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"lines": lines})
}

func handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		cfg, err := readConfig()
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(cfg)

	case http.MethodPost:
		var cfg Config
		if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
			jsonError(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
			return
		}
		if err := writeConfig(&cfg); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_ = exec.Command("killall", "mediaserverd").Run()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})

	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/api/status", handleStatus)
	mux.HandleFunc("/api/logs", handleLogs)
	mux.HandleFunc("/api/config", handleConfig)

	log.Printf("HomePod Dashboard listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
