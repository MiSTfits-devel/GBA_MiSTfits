# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
#
# Append these lines to /media/fat/linux/user-startup.sh to bring the GBA
# Wireless Adapter emulation up at boot. The daemon is idle unless the core's
# Multiplayer option is set to "Wireless (Emulated)", so it is safe to leave
# resident. See support/rfu_daemon/README.md.

# Two MiSTers on one LAN need nothing else -- they find each other. For play
# over the internet, add: -P their.host.or.ip  (and forward udp/55440)
[ -x /media/fat/linux/rfu_daemon ] && \
    /media/fat/linux/rfu_daemon -d /dev/ttyS1 >/dev/null 2>&1 &
