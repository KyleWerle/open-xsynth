// Ableton Link -> OSC bridge for the Open XSynth (SuperCollider 3.7 has no LinkClock).
// Runs as a Link peer; streams session tempo + beat + bar-phase + peer count to sclang
// (127.0.0.1:57120) at 50 Hz. SC does the tempo/phase lock. Core sockets only, no OSC lib.
//
// build: g++ -std=c++14 -O2 -pthread -DASIO_STANDALONE \
//   -I link/include -I link/modules/asio-standalone/asio/include bridge.cpp -o linkbridge -latomic
#include <ableton/Link.hpp>
#include <chrono>
#include <thread>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static void putStr(uint8_t* b, int& n, const char* s) {
    int len = (int)std::strlen(s);
    std::memcpy(b + n, s, len); n += len;
    b[n++] = 0;
    while (n % 4) b[n++] = 0;
}
static void putF(uint8_t* b, int& n, float f) {
    uint32_t x; std::memcpy(&x, &f, 4); x = htonl(x); std::memcpy(b + n, &x, 4); n += 4;
}
static void putI(uint8_t* b, int& n, int32_t i) {
    uint32_t x = htonl((uint32_t)i); std::memcpy(b + n, &x, 4); n += 4;
}

int main(int argc, char** argv) {
    const char* host = (argc > 1) ? argv[1] : "127.0.0.1";
    int port = (argc > 2) ? std::atoi(argv[2]) : 57120;
    const double quantum = 4.0;                 // 4/4 bar

    ableton::Link link(120.0);
    link.enable(true);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in dst;
    std::memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &dst.sin_addr);

    for (;;) {
        auto state = link.captureAppSessionState();
        auto now = link.clock().micros();
        double tempo = state.tempo();
        double beat = state.beatAtTime(now, quantum);
        double phase = state.phaseAtTime(now, quantum);   // 0..quantum
        double barPhase = phase / quantum;                // 0..1
        int peers = (int)link.numPeers();

        uint8_t buf[128]; int n = 0;
        putStr(buf, n, "/link/state");
        putStr(buf, n, ",fffi");
        putF(buf, n, (float)tempo);
        putF(buf, n, (float)beat);
        putF(buf, n, (float)barPhase);
        putI(buf, n, peers);
        sendto(sock, buf, n, 0, (sockaddr*)&dst, sizeof(dst));

        std::this_thread::sleep_for(std::chrono::milliseconds(20));  // 50 Hz
    }
    return 0;
}
