// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone probe: does a single daemon's LAN-discovery HELLO come back to
// its own socket and get interned as a peer? Run one instance only.
#include "rfu_core.h"
#include "rfu_net.h"

#include <stdarg.h>
#include <stdio.h>
#include <time.h>

uint32_t rfu_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

void rfu_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "    | ");
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

int main(void)
{
    rfu_core_init();
    if (rfu_net_open(55471, 1) < 0) {
        fprintf(stderr, "cannot open socket\n");
        return 2;
    }

    printf("single daemon, LAN discovery on, no other instance running\n");

    // ~3 seconds of the daemon's real loop; HELLO goes out once a second.
    for (int i = 0; i < 200; i++) {
        struct timespec ts = { 0, 16 * 1000000 };
        rfu_net_poll();
        rfu_core_frame();
        rfu_net_tick();
        nanosleep(&ts, NULL);
    }

    int n = rfu_net_peer_count();
    printf("peers discovered: %d\n", n);
    for (int i = 0; i < n; i++)
        printf("  peer %d: %s\n", i, rfu_net_peer_name(i));

    if (n > 0) {
        printf("RESULT: SELF-DISCOVERY BUG -- the daemon interned its own "
               "broadcast as a peer.\n");
        return 1;
    }
    printf("RESULT: clean, no self-discovery.\n");
    return 0;
}
