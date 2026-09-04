// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Two Dice Ltd
//
// This file is part of the Morke VPN Network Extension, which statically links
// sing-box (https://github.com/SagerNet/sing-box), licensed GPL-3.0-or-later.
// GPLv3 § 5(c) requires the entire work, as a whole, to be licensed under the same
// terms to anyone who comes into possession of a copy — so this file is GNU General
// Public License v3 or later.
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.
//
// Corresponding Source (GPLv3 § 6) and the build recipe that produced the object
// code: README.md and BUILD.md in the repository this file is published from.

//
//  MorkeTunnelNetHelpers.c
//  MorkeTunnel
//
//  See MorkeTunnelNetHelpers.h. The logic here is lifted verbatim from the
//  inline helpers in ExtensionPlatformInterface.m and must stay byte-for-byte
//  behaviour-identical to them — the .m calls into these instead of duplicating
//  the routing / parse math.
//

#include "MorkeTunnelNetHelpers.h"

#include <string.h>
#include <net/if.h>
#include <netinet/in.h>

// Returns false for loopback, down, and Apple-internal / tunnel interfaces.
bool morke_is_physical_interface(const char *name, unsigned int flags) {
    if (flags & IFF_LOOPBACK)              return false;
    if (!(flags & IFF_UP))                 return false;
    if (strncmp(name, "utun",   4) == 0)   return false;
    if (strncmp(name, "awdl",   4) == 0)   return false;
    if (strncmp(name, "llw",    3) == 0)   return false;
    if (strncmp(name, "anpi",   4) == 0)   return false;
    if (strncmp(name, "stf",    3) == 0)   return false;
    if (strncmp(name, "gif",    3) == 0)   return false;
    if (strncmp(name, "bridge", 6) == 0)   return false;
    if (strncmp(name, "ipsec",  5) == 0)   return false;
    return true;
}

// Maps iOS interface name prefix to a libbox-free interface-type code.
int32_t morke_interface_type_for_name(const char *name) {
    if (strncmp(name, "en",     2) == 0) return MorkeInterfaceTypeWIFI;
    if (strncmp(name, "pdp_ip", 6) == 0) return MorkeInterfaceTypeCellular;
    if (strncmp(name, "rmnet",  5) == 0) return MorkeInterfaceTypeCellular;
    return MorkeInterfaceTypeOther;
}

int morke_ipv4_netmask_prefix(const struct sockaddr *netmask) {
    int prefix = 0;
    if (netmask && netmask->sa_family == AF_INET) {
        // Darwin getifaddrs returns netmask sockaddrs with a TRUNCATED sa_len
        // (trailing all-zero bytes dropped), so read s_addr only within sa_len
        // and treat missing trailing bytes as 0 — reading the full 4 bytes
        // unconditionally would over-read past the entry getifaddrs allocated.
        const struct sockaddr_in *m = (const struct sockaddr_in *)netmask;
        const uint8_t *mb = (const uint8_t *)&m->sin_addr; // offset 4 in sockaddr_in
        size_t mlen = netmask->sa_len;
        uint32_t mask = 0;
        for (int i = 0; i < 4 && (size_t)(4 + i) < mlen; i++) {
            mask |= (uint32_t)mb[i] << (24 - 8 * i);
        }
        while (mask & 0x80000000U) { prefix++; mask <<= 1; }
    }
    return prefix;
}

int morke_ipv6_netmask_prefix(const struct sockaddr *netmask) {
    int prefix = 0;
    if (netmask && netmask->sa_family == AF_INET6) {
        // Same Darwin sa_len truncation as IPv4: bound the 16-byte mask read by
        // sa_len and treat missing trailing bytes as 0x00 (zero contributes 0 to
        // the prefix — exactly Darwin's truncation semantics). A fixed 16-byte
        // read at offset 8 over-reads past a truncated mask entry.
        size_t mlen = netmask->sa_len;
        const uint8_t *maskBytes = (const uint8_t *)netmask + 8;
        for (int i = 0; i < 16 && (size_t)(8 + i) < mlen; i++) {
            uint8_t byte = maskBytes[i];
            while (byte & 0x80U) { prefix++; byte <<= 1; }
            if (byte != 0) break;
        }
    }
    return prefix;
}

bool morke_ipv6_is_link_local(const struct sockaddr *addr) {
    // Reject NULL / non-AF_INET6 / a sockaddr too short to hold the two bytes
    // this reads (sin6_addr[0..1] at offsets 8 and 9, so sa_len must be >= 10) —
    // parity with the NULL / sa_family / sa_len guards the netmask helpers above
    // use. The lone call site (ExtensionPlatformInterface.m getInterfaces) already
    // passes only full AF_INET6 address sockaddrs, so this is a crash-safety /
    // defense-in-depth floor, not a live fix.
    if (!addr || addr->sa_family != AF_INET6 || addr->sa_len < 10) return false;
    // On Darwin, struct sockaddr_in6 layout (RFC 3493 / xnu ABI):
    //   sin6_len(1), sin6_family(1), sin6_port(2), sin6_flowinfo(4),
    //   sin6_addr(16), sin6_scope_id(4) — sin6_addr starts at byte offset 8.
    // Avoid including <netinet6/in6.h> (private module on the iOS SDK).
    const uint8_t *addrBytes = (const uint8_t *)addr + 8;
    return addrBytes[0] == 0xfe && (addrBytes[1] & 0xc0) == 0x80;
}
