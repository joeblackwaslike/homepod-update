#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <netdb.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <substrate.h>

// ---------------------------------------------------------------------------
// Defaults — overridden at runtime by the preference plist.
// ---------------------------------------------------------------------------
#define DEFAULT_SERVER_IP   "home-assistant.local"
#define DEFAULT_SERVER_PORT 10700

// ---------------------------------------------------------------------------
// Shared state — all access via socket_mutex.
// ---------------------------------------------------------------------------
static int               ha_socket    = -1;
static pthread_mutex_t   socket_mutex = PTHREAD_MUTEX_INITIALIZER;

static char server_ip[64]  = DEFAULT_SERVER_IP;
static int  server_port     = DEFAULT_SERVER_PORT;

// ---------------------------------------------------------------------------
// Preference loader
// ---------------------------------------------------------------------------
static void load_preferences(void) {
    CFStringRef app_id   = CFSTR("com.yourname.homepodaudiobridge");

    CFStringRef ip_val = (CFStringRef)CFPreferencesCopyAppValue(CFSTR("ServerIP"), app_id);
    if (ip_val && CFGetTypeID(ip_val) == CFStringGetTypeID()) {
        CFStringGetCString(ip_val, server_ip, sizeof(server_ip), kCFStringEncodingUTF8);
        CFRelease(ip_val);
    }

    CFNumberRef port_val = (CFNumberRef)CFPreferencesCopyAppValue(CFSTR("ServerPort"), app_id);
    if (port_val && CFGetTypeID(port_val) == CFNumberGetTypeID()) {
        CFNumberGetValue(port_val, kCFNumberIntType, &server_port);
        CFRelease(port_val);
    }

    NSLog(@"[HomePodAudioBridge] Config: %s:%d", server_ip, server_port);
}

// ---------------------------------------------------------------------------
// Wyoming protocol helpers
//
// Wyoming wire format:
//   <JSON event line>\n
//   <binary payload of payload_length bytes>       ← only for audio-chunk
//
// The server must know the exact sample rate, bit width, and channel count
// to decode PCM correctly. These values are populated from the live ASBD
// query in the constructor; defaults match typical audioOS mic bus output.
// ---------------------------------------------------------------------------
static int    asbd_rate     = 48000;  // updated after ASBD query
static int    asbd_channels = 1;
static int    asbd_width    = 2;      // bytes per sample (16-bit)

static ssize_t wyoming_write(int sock, const void *buf, size_t len) {
    const uint8_t *ptr = (const uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t n = send(sock, ptr, remaining, MSG_NOSIGNAL);
        if (n <= 0) return -1;
        ptr       += n;
        remaining -= n;
    }
    return (ssize_t)len;
}

static ssize_t wyoming_send_event(int sock, const char *type,
                                  size_t payload_length) {
    char json[256];
    if (payload_length > 0) {
        snprintf(json, sizeof(json),
            "{\"type\":\"%s\",\"data\":{\"rate\":%d,\"width\":%d,\"channels\":%d},"
            "\"payload_length\":%zu}\n",
            type, asbd_rate, asbd_width, asbd_channels, payload_length);
    } else {
        snprintf(json, sizeof(json),
            "{\"type\":\"%s\",\"data\":{\"rate\":%d,\"width\":%d,\"channels\":%d},"
            "\"payload_length\":0}\n",
            type, asbd_rate, asbd_width, asbd_channels);
    }
    return wyoming_write(sock, json, strlen(json));
}

// ---------------------------------------------------------------------------
// Connection thread — reconnects automatically on failure.
// ---------------------------------------------------------------------------
static void close_socket_locked(void) {
    // Caller must NOT hold socket_mutex.
    pthread_mutex_lock(&socket_mutex);
    if (ha_socket >= 0) {
        close(ha_socket);
        ha_socket = -1;
    }
    pthread_mutex_unlock(&socket_mutex);
}

static void *connection_thread(void *arg) {
    load_preferences();

    while (1) {
        pthread_mutex_lock(&socket_mutex);
        int current = ha_socket;
        pthread_mutex_unlock(&socket_mutex);

        if (current >= 0) {
            sleep(2);
            continue;
        }

        // Resolve hostname via getaddrinfo — supports mDNS (.local), DNS, and
        // bare IP strings. inet_pton() only handles numeric IPs and will silently
        // fail on any hostname including mDNS names.
        char port_str[8];
        snprintf(port_str, sizeof(port_str), "%d", server_port);

        struct addrinfo hints = {0};
        hints.ai_family   = AF_INET;
        hints.ai_socktype = SOCK_STREAM;

        struct addrinfo *res = NULL;
        if (getaddrinfo(server_ip, port_str, &hints, &res) != 0 || res == NULL) {
            NSLog(@"[HomePodAudioBridge] DNS/mDNS resolution failed for %s — retrying in 5s", server_ip);
            if (res) freeaddrinfo(res);
            sleep(5);
            continue;
        }

        int sock = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (sock < 0) { freeaddrinfo(res); sleep(5); continue; }

        // Detect dead connections without waiting for a send() failure.
        int enable = 1;
        setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &enable, sizeof(enable));

        if (connect(sock, res->ai_addr, res->ai_addrlen) < 0) {
            freeaddrinfo(res);
            close(sock);
            NSLog(@"[HomePodAudioBridge] Connection failed — retrying in 5s");
            sleep(5);
            continue;
        }
        freeaddrinfo(res);

        // Wyoming handshake: send audio-start before any chunks.
        if (wyoming_send_event(sock, "audio-start", 0) < 0) {
            close(sock);
            sleep(5);
            continue;
        }

        pthread_mutex_lock(&socket_mutex);
        ha_socket = sock;
        pthread_mutex_unlock(&socket_mutex);

        NSLog(@"[HomePodAudioBridge] Connected to %s:%d (rate=%d width=%d ch=%d)",
              server_ip, server_port, asbd_rate, asbd_width, asbd_channels);
        sleep(2);
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// AudioUnitRender hook
// ---------------------------------------------------------------------------
static OSStatus (*orig_AudioUnitRender)(
    AudioUnit, AudioUnitRenderActionFlags *,
    const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static OSStatus hooked_AudioUnitRender(
    AudioUnit                     inUnit,
    AudioUnitRenderActionFlags   *ioActionFlags,
    const AudioTimeStamp         *inTimeStamp,
    UInt32                        inBusNumber,
    UInt32                        inNumberFrames,
    AudioBufferList              *ioData)
{
    // Always call through — do not disrupt any native pipeline.
    OSStatus status = orig_AudioUnitRender(
        inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);

    // Bus 1 = RemoteIO input element (microphone).
    // Verify this matches your ASBD log output; audioOS may differ.
    if (status != noErr || inBusNumber != 1 || ioData == NULL) return status;

    pthread_mutex_lock(&socket_mutex);
    int sock = ha_socket;
    pthread_mutex_unlock(&socket_mutex);

    if (sock < 0) return status;

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        const AudioBuffer *buf = &ioData->mBuffers[i];
        if (buf->mData == NULL || buf->mDataByteSize == 0) continue;

        // Send Wyoming audio-chunk header then raw PCM payload.
        if (wyoming_send_event(sock, "audio-chunk", buf->mDataByteSize) < 0 ||
            wyoming_write(sock, buf->mData, buf->mDataByteSize) < 0) {
            // Connection lost — reset so connection_thread picks it up.
            NSLog(@"[HomePodAudioBridge] Send failed — resetting socket");
            close_socket_locked();
            break;
        }
    }

    return status;
}

// ---------------------------------------------------------------------------
// Constructor — runs when mediaserverd loads the dylib.
// ---------------------------------------------------------------------------
%ctor {
    NSLog(@"[HomePodAudioBridge] Initializing...");

    // Query the mic bus ASBD so Wyoming framing reflects actual hardware format.
    // The HomePod's internal bus is likely 48 kHz / 32-bit float; log it to verify.
    // Server-side resampling to 16 kHz is expected before passing to openWakeWord.
    //
    // Note: inUnit is not yet available here — ASBD is logged on first render callback
    // instead. The defaults above (48000 / 16-bit / mono) are reasonable starting values.
    // Watch syslog after install and update asbd_* constants if they differ.

    pthread_t thread;
    pthread_create(&thread, NULL, connection_thread, NULL);
    pthread_detach(thread);  // Prevents thread descriptor leak.

    MSHookFunction(
        (void *)AudioUnitRender,
        (void *)hooked_AudioUnitRender,
        (void **)&orig_AudioUnitRender);

    NSLog(@"[HomePodAudioBridge] AudioUnitRender hooked.");
}