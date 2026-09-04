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

#import "ExtensionPlatformInterface.h"
#import <os/log.h>
@import Network;

#include <stdatomic.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>

#include "MorkeTunnelNetHelpers.h"

// IPV6_BOUND_IF is declared in <netinet6/in6.h>, which is a private module on the
// iOS SDK. The value 125 is stable across Darwin kernel versions (xnu ABI).
#ifndef IPV6_BOUND_IF
#define IPV6_BOUND_IF 125
#endif

// ---------------------------------------------------------------------------
// MARK: - Shared os_log handle

// Single os_log destination for the whole extension lifetime. Subsystem/category
// match PacketTunnelProvider's Swift Logger so the entire NE appears under one
// Console.app filter: Subsystem = "tech.twodice.morke", Category = "tunnel".
// NOTE: independent of Swift — keep byte-identical by hand with MorkeShared.MorkeLog.subsystem,
// MorkeFeatures.FeatureLog.subsystem, and MorkeGlobe.GlobeLog.subsystem (mirrors the
// SharedKeychain.swift:16-17 warning): a rename that misses one silently splits the Console.app filter.
static os_log_t MorkeTunnelLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("tech.twodice.morke", "tunnel");
    });
    return log;
}

#define kMorkeTunnelErrorDomain @"SingBoxTunnel"

// ---------------------------------------------------------------------------
// MARK: - Helper iterators

@interface EXTStringIterator : NSObject <LibboxStringIterator>
@property (nonatomic, strong) NSArray<NSString *> *items;
@property (nonatomic)         NSInteger            cursor;
- (instancetype)initWithStrings:(NSArray<NSString *> *)strings;
@end

@implementation EXTStringIterator
- (instancetype)initWithStrings:(NSArray<NSString *> *)strings {
    self = [super init];
    if (self) { _items = strings ?: @[]; _cursor = 0; }
    return self;
}
- (BOOL)hasNext { return _cursor < (NSInteger)_items.count; }
- (int32_t)len  { return (int32_t)_items.count; }
- (NSString *)next {
    // Bounds floor: libbox is expected to honour hasNext, but an out-of-contract
    // next must not index past the end — an NSRangeException crosses into the Go
    // cgo frame uncatchable and hard-kills the extension. Return @"" (protocol
    // next is _Nonnull) without advancing instead.
    if (_cursor >= (NSInteger)_items.count) { return @""; }
    return _items[_cursor++];
}
@end

@interface EXTNetworkInterfaceIterator : NSObject <LibboxNetworkInterfaceIterator>
@property (nonatomic, strong) NSArray<LibboxNetworkInterface *> *interfaces;
@property (nonatomic)         NSInteger                          cursor;
- (instancetype)initWithInterfaces:(NSArray<LibboxNetworkInterface *> *)interfaces;
@end

@implementation EXTNetworkInterfaceIterator
- (instancetype)initWithInterfaces:(NSArray<LibboxNetworkInterface *> *)interfaces {
    self = [super init];
    if (self) { _interfaces = interfaces ?: @[]; _cursor = 0; }
    return self;
}
- (BOOL)hasNext { return _cursor < (NSInteger)_interfaces.count; }
- (LibboxNetworkInterface *)next {
    // Bounds floor: as with EXTStringIterator, an out-of-contract next must not
    // raise NSRangeException. The result is consumed by gobind, which reads the
    // interface's properties, so returning nil would only trade the ObjC exception
    // for a Go-side nil-deref. Return a valid empty interface instead: name is
    // _Nonnull and addresses is iterated, so both get safe empty defaults.
    if (_cursor >= (NSInteger)_interfaces.count) {
        LibboxNetworkInterface *empty = [[LibboxNetworkInterface alloc] init];
        empty.name      = @"";
        empty.addresses = [[EXTStringIterator alloc] initWithStrings:@[]];
        return empty;
    }
    return _interfaces[_cursor++];
}
@end

// ---------------------------------------------------------------------------
// MARK: - Static helpers
//
// The pure interface-classification and netmask/fe80 parse helpers live in
// MorkeTunnelNetHelpers.c/.h (Foundation/libbox-free) so they can be unit-tested
// off-device (T-TEST-UNIT-12). This file maps the libbox-free interface-type
// code returned by morke_interface_type_for_name() to the LibboxInterfaceType*
// constants at the getInterfaces: call site.

// ---------------------------------------------------------------------------

@interface ExtensionPlatformInterface () {
    // Written by the nw_path_monitor handler (monitorQueue).
    // Read by libbox goroutine threads (autoDetectInterfaceControl:).
    // C11 atomic ensures cross-thread visibility without additional locks.
    _Atomic int32_t _currentIfaceIndex;

    // _pathMonitor and its one-way torn-down latch are deliberately NOT properties: every
    // read/write lives inside a dispatch_sync onto the serial monitorQueue (see
    // startDefaultInterfaceMonitor: / tearDownPathMonitor). Queue confinement — not atomicity —
    // is what makes the set/clear SINGLE-OWNER: the store (a libbox goroutine) and the two
    // teardown callers (reset on the NE provider queue, closeDefaultInterfaceMonitor: on a libbox
    // goroutine) are serialized onto one queue, so two threads can never run the check-cancel-nil
    // objc_storeStrong concurrently and double-release the monitor (audit F-2). A bare `atomic`
    // property could NOT express that: atomicity guards each store in isolation, not the
    // read-cancel-nil sequence. The serial queue also supplies the happens-before for these plain
    // (non-atomic) fields. nw_path_monitor_t is an ARC object type, so `_pathMonitor` is a strong
    // ivar (assignment retains, `= nil` releases) — identical memory semantics to the former
    // strong property, minus the racy accessor.
    nw_path_monitor_t _pathMonitor;
    BOOL              _pathMonitorTornDown;
}
@property (nonatomic, weak)   NEPacketTunnelProvider               *provider;
// interfaceListener and myInterfaceName are read/written from libbox goroutines and
// the nw_path_monitor handler (monitorQueue) — different threads with no shared lock.
// atomic accessors close the torn-pointer / ARC over-release window across goroutines
// (mirrors the _Atomic _currentIfaceIndex intent above). All access must go through
// the property accessors (self.x), never the bare ivar, for the atomicity to hold.
@property (atomic, strong)    id<LibboxInterfaceUpdateListener>     interfaceListener;
@property (nonatomic, strong) dispatch_queue_t                      monitorQueue;
// Name of the TUN interface registered by libbox; excluded from getInterfaces:.
@property (atomic, copy)      NSString                             *myInterfaceName;
@end

@implementation ExtensionPlatformInterface

// +load is invoked by the ObjC runtime when the image is mapped into the process,
// before any Go runtime initialisation or PacketTunnelProvider init runs.
// Subsystem/category match PacketTunnelProvider so the full extension lifetime
// appears under a single Console.app filter: Subsystem = "tech.twodice.morke".
//
// Diagnostic key:
//   • This line ABSENT after Connect → extension process never spawned, or dyld
//     crashed pre-main (check device crash logs in Xcode → Window → Devices & Simulators).
//   • This line PRESENT but PacketTunnelProvider init ABSENT → crash between image
//     load and ObjC/Swift object graph construction (Go runtime init or static ctor).
+ (void)load {
    os_log(MorkeTunnelLog(), "singbox: image +load");
}

- (instancetype)initWithProvider:(NEPacketTunnelProvider *)provider {
    self = [super init];
    if (self) {
        _provider     = provider;
        _monitorQueue = dispatch_queue_create("tech.twodice.morke.tunnel.monitor",
                                              DISPATCH_QUEUE_SERIAL);
        atomic_init(&_currentIfaceIndex, 0);
    }
    return self;
}

- (void)tearDownPathMonitor {
    // Single-owner teardown. Confine cancel+nil of _pathMonitor to the serial monitorQueue so it
    // can never race the publish in startDefaultInterfaceMonitor: (also monitorQueue-confined):
    // this method's two callers — reset() on the NE provider queue and closeDefaultInterfaceMonitor:
    // on a libbox goroutine — previously ran this nonatomic objc_storeStrong concurrently and could
    // both release the same monitor (over-release → use-after-free mid-disconnect, audit F-2).
    // Serializing every mutation of _pathMonitor onto one queue removes that race WITHOUT holding a
    // lock across an nw_* call.
    //
    // F-6: the nw_path update handler ALSO runs on monitorQueue, so this dispatch_sync first DRAINS
    // any in-flight handler, THEN cancels; after nw_path_monitor_cancel no further handler fires, and
    // nil-ing interfaceListener on-queue makes any late block that still slips through read nil and
    // no-op — so no updateDefaultInterface: can reach an already-closed engine.
    //
    // No self-deadlock: the ONLY code that ever runs on monitorQueue is that update handler, and it
    // calls updateDefaultInterface: only — it never re-enters tearDownPathMonitor, the publish,
    // reset, or closeDefaultInterfaceMonitor:. The provider queue and the libbox goroutines are not
    // monitorQueue, so dispatch_sync is never issued from the target queue itself.
    dispatch_sync(self.monitorQueue, ^{
        self->_pathMonitorTornDown = YES;
        if (self->_pathMonitor) {
            nw_path_monitor_cancel(self->_pathMonitor);
            self->_pathMonitor = nil;
        }
        self.interfaceListener = nil;
    });
}

- (void)reset {
    [self tearDownPathMonitor];
}

// MARK: - LibboxPlatformInterface — TUN setup

// Called by libbox when it needs to bring up the TUN interface.
// Builds NEPacketTunnelNetworkSettings from the TUN inbound config,
// applies them via setTunnelNetworkSettings, then returns the TUN fd.
- (BOOL)openTun:(id<LibboxTunOptions>)options
          ret0_:(int32_t *)ret0_
          error:(NSError **)error {
    if (!options || !ret0_) {
        if (error) {
            *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:10
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"nil TUN options or return pointer"}];
        }
        return NO;
    }
    NEPacketTunnelProvider *provider = self.provider;
    if (!provider) {
        if (error) {
            *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:11
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"provider already deallocated"}];
        }
        return NO;
    }

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"127.0.0.1"];
    settings.MTU = @([options getMTU]);

    // IPv4 — libbox passes LibboxRoutePrefix with address and mask (e.g. "172.19.0.1" / "255.255.255.252")
    NSMutableArray<NSString *> *v4Addrs = [NSMutableArray array];
    NSMutableArray<NSString *> *v4Masks = [NSMutableArray array];
    id<LibboxRoutePrefixIterator> iter4 = [options getInet4Address];
    while (iter4 && [iter4 hasNext]) {
        LibboxRoutePrefix *rp = [iter4 next];
        if (rp) {
            [v4Addrs addObject:[rp address]];
            [v4Masks addObject:[rp mask]];
        }
    }
    if (v4Addrs.count > 0) {
        NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:v4Addrs
                                                             subnetMasks:v4Masks];
        if ([options getAutoRoute]) {
            ipv4.includedRoutes = @[[NEIPv4Route defaultRoute]];
        }
        settings.IPv4Settings = ipv4;
    }

    // IPv6 — prefix length comes from -[LibboxRoutePrefix prefix]
    NSMutableArray<NSString *> *v6Addrs    = [NSMutableArray array];
    NSMutableArray<NSNumber *> *v6Prefixes = [NSMutableArray array];
    id<LibboxRoutePrefixIterator> iter6 = [options getInet6Address];
    while (iter6 && [iter6 hasNext]) {
        LibboxRoutePrefix *rp = [iter6 next];
        if (rp) {
            [v6Addrs    addObject:[rp address]];
            [v6Prefixes addObject:@([rp prefix])];
        }
    }
    if (v6Addrs.count > 0) {
        NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc] initWithAddresses:v6Addrs
                                                    networkPrefixLengths:v6Prefixes];
        if ([options getAutoRoute]) {
            ipv6.includedRoutes = @[[NEIPv6Route defaultRoute]];
        }
        settings.IPv6Settings = ipv6;
    } else if (v4Addrs.count > 0) {
        // L1 / T-REL-2 leak-block marker. A v4-only config claims no IPv6 route: on a dual-stack
        // network with the kill switch OFF the OS can still send IPv6 straight to the open internet
        // around the tunnel. Since B-SAFE-6 every emitted config carries an IPv6 ULA (api.md
        // §auth/config), so zero v6 addresses means a server regression re-emitting an IPv4-only
        // config — a silent v6-leak reopening. Emit a loud, non-sensitive marker (no addresses
        // logged) so the T-REL-2 device runbook catches it. Not fail-closed: dropping the whole
        // start on a v4-only config is the maintainer's call; the marker is the default.
        os_log_error(MorkeTunnelLog(),
                     "[sing-box] openTun: IPv4-only config, no IPv6Settings claimed — potential v6 leak on dual-stack (T-REL-2)");
    }

    // DNS
    //
    // M7: fail CLOSED when auto_route captured the default route but no usable resolver is
    // available. A swallowed getDNSServerAddress: error (or zero servers) used to apply settings
    // with nil DNSSettings, leaving the system/LAN resolver active — cleartext DNS on the
    // directly-connected subnet route whenever the kill switch is off. Today's configs always carry
    // DNS (the hijack-dns design depends on it), so this aborts only a server regression, not the
    // live path.
    NSError *dnsErr = nil;
    id<LibboxStringIterator> dnsIter = [options getDNSServerAddress:&dnsErr];
    NSMutableArray<NSString *> *dnsServers = [NSMutableArray array];
    if (!dnsErr && dnsIter) {
        while ([dnsIter hasNext]) {
            [dnsServers addObject:[dnsIter next]];
        }
    }
    if (dnsServers.count > 0) {
        NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:dnsServers];
        // matchDomains = @[@""] makes the resolver override hold for ALL queries, not only while
        // the tunnel owns the default route (sing-box-for-apple parity). No-op on today's
        // full-tunnel configs; matters once a T-ROUTE split-tunnel config exists.
        dns.matchDomains = @[@""];
        settings.DNSSettings = dns;
    } else if ([options getAutoRoute]) {
        // No usable DNS under auto_route → hard-fail the start (same pattern as the settings-error /
        // timeout aborts below), before any settings are applied, rather than falling open to the
        // LAN resolver. Log the swallowed dnsErr loudly — it is a DNS-retrieval mechanism error,
        // never resolver contents.
        os_log_error(MorkeTunnelLog(),
                     "[sing-box] openTun: no usable DNS under auto_route — aborting start (dnsErr: %{public}@)",
                     dnsErr ? dnsErr.localizedDescription : @"nil (zero servers)");
        if (error) {
            *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:14
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"no usable DNS servers under auto_route"}];
        }
        return NO;
    }

    // Apply network settings — synchronous bridge from Go goroutine.
    // Safe only because box.start() runs on a background queue (see PacketTunnelProvider):
    // the NE provider queue is free to deliver the completion; the semaphore signals
    // without delay. 10-second guard catches any future regression where the queue is blocked.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *settingsError = nil;
    [provider setTunnelNetworkSettings:settings completionHandler:^(NSError *e) {
        settingsError = e;
        dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) != 0) {
        // Timeout means the provider queue never delivered the completion — the exact
        // blocked-queue regression this guard exists to catch. Settings are NOT applied;
        // fail the start cleanly instead of returning a half-up TUN that would route
        // packets with no OS-applied routing/DNS (a leak / black-hole window).
        os_log_error(MorkeTunnelLog(), "[sing-box] setTunnelNetworkSettings timed out after 10 s");
        if (error) {
            *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:13
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"setTunnelNetworkSettings timed out"}];
        }
        return NO;
    }
    // A non-nil completion error means the OS rejected the settings (invalid
    // IPv4/IPv6/DNS/route). Surface it instead of reading a possibly-stale fd and
    // reporting success on an unconfigured tunnel.
    if (settingsError) {
        os_log_error(MorkeTunnelLog(), "[sing-box] setTunnelNetworkSettings failed: %{public}@",
                     settingsError.localizedDescription);
        if (error) { *error = settingsError; }
        return NO;
    }

    // Read TUN fd via KVO — officially endorsed in sing-box-for-apple. The private
    // key path raises NSUnknownKeyException (not nil) if Apple ever removes the
    // socket/fileDescriptor properties; the @catch keeps the documented
    // LibboxGetTunnelFileDescriptor() fallback below reachable instead of letting an
    // uncaught ObjC exception abort the libbox goroutine.
    NSNumber *fdNum = nil;
    @try {
        fdNum = [provider.packetFlow valueForKeyPath:@"socket.fileDescriptor"];
    } @catch (NSException *exception) {
        os_log_error(MorkeTunnelLog(), "[sing-box] packetFlow fd KVO read failed: %{public}@",
                     exception.name);
        fdNum = nil;
    }
    int32_t fd = (fdNum != nil) ? [fdNum intValue] : -1;
    if (fd >= 0) {
        *ret0_ = fd;
        return YES;
    }
    // Fallback: ask libbox for the fd it may have acquired during its own TUN setup.
    fd = LibboxGetTunnelFileDescriptor();
    if (fd >= 0) {
        *ret0_ = fd;
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:12
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                @"failed to obtain TUN file descriptor"}];
    }
    return NO;
}

// MARK: - LibboxPlatformInterface — control socket

- (BOOL)usePlatformAutoDetectInterfaceControl { return NO; }

// Binds the outgoing socket to the current physical default interface so that
// non-TUN traffic (proxy connections, DNS, health checks) bypasses the VPN.
// sing-box calls this for every socket it creates when usePlatformAutoDetectInterfaceControl=NO.
- (BOOL)autoDetectInterfaceControl:(int32_t)fd error:(NSError **)error {
    int32_t ifindex = atomic_load(&_currentIfaceIndex);
    if (ifindex == 0) return YES; // interface not yet known — skip binding, don't fail

    uint32_t uindex = (uint32_t)ifindex;

    // Bind IPv4 socket to the physical interface.
    if (setsockopt((int)fd, IPPROTO_IP, IP_BOUND_IF, &uindex, sizeof(uindex)) != 0) {
        os_log_error(MorkeTunnelLog(), "[sing-box] IP_BOUND_IF ifindex=%u: %{public}s", uindex, strerror(errno));
    }
    // Bind IPv6 socket to the same interface (harmless on IPv4-only sockets).
    if (setsockopt((int)fd, IPPROTO_IPV6, IPV6_BOUND_IF, &uindex, sizeof(uindex)) != 0) {
        os_log_error(MorkeTunnelLog(), "[sing-box] IPV6_BOUND_IF ifindex=%u: %{public}s", uindex, strerror(errno));
    }
    // Return YES even on partial failure — matching sing-box-for-apple behaviour.
    return YES;
}

- (BOOL)usePlatformShell { return NO; }
- (BOOL)checkPlatformShell:(NSError **)error { return YES; }
- (BOOL)useProcFS { return NO; }

- (nullable LibboxConnectionOwner *)findConnectionOwner:(int32_t)ipProtocol
                                          sourceAddress:(nullable NSString *)sourceAddress
                                             sourcePort:(int32_t)sourcePort
                                     destinationAddress:(nullable NSString *)destinationAddress
                                        destinationPort:(int32_t)destinationPort
                                                  error:(NSError **)error {
    // procfs unavailable on iOS — return nil (libbox falls back to uid 0).
    return nil;
}

// MARK: - LibboxPlatformInterface — interface monitoring

- (BOOL)startDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener>)listener
                               error:(NSError **)error {
    self.interfaceListener = listener;
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        __block NSString *name  = @"";
        __block int32_t  index  = 0;
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t iface) {
            const char *cName = nw_interface_get_name(iface);
            if (cName) {
                name  = [NSString stringWithUTF8String:cName];
                // nw_interface_get_index returns uint32_t; cast is safe (index < 2^31).
                index = (int32_t)nw_interface_get_index(iface);
            }
            return false; // stop after first (highest-priority) interface
        });

        // Publish new index so autoDetectInterfaceControl: picks it up on next call.
        atomic_store(&strongSelf->_currentIfaceIndex, index);

        BOOL isExpensive   = nw_path_is_expensive(path);
        BOOL isConstrained = nw_path_is_constrained(path);
        [strongSelf.interfaceListener updateDefaultInterface:name
                                             interfaceIndex:index
                                                isExpensive:isExpensive
                                             isConstrained:isConstrained];
    });
    nw_path_monitor_set_queue(monitor, self.monitorQueue);
    nw_path_monitor_start(monitor);
    // Publish the monitor on monitorQueue so the store is single-owner with tearDownPathMonitor
    // (same serial queue — see the _pathMonitor ivar note). The torn-down latch closes the
    // stop-during-start window (T-CFG-28): if reset()/closeDefaultInterfaceMonitor: already tore the
    // monitor down while we were building and starting THIS one, publishing it would strand a
    // started monitor whose live handler keeps firing updateDefaultInterface: into an engine that is
    // already closing. When the latch shows teardown won the race, cancel the just-built monitor
    // on-queue instead of publishing it (and drop the listener set at the top of this method).
    // dispatch_sync cannot deadlock here: monitorQueue only ever runs the update handler, never this
    // method (see tearDownPathMonitor).
    dispatch_sync(self.monitorQueue, ^{
        if (self->_pathMonitorTornDown) {
            nw_path_monitor_cancel(monitor);
            self.interfaceListener = nil;
            return;
        }
        self->_pathMonitor = monitor;
    });
    return YES;
}

- (BOOL)closeDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener>)listener
                               error:(NSError **)error {
    [self tearDownPathMonitor];
    return YES;
}

// Returns the real physical interfaces via getifaddrs(3).
// sing-box uses this list to resolve the default interface by name/index and
// to apply per-interface routing rules.
- (nullable id<LibboxNetworkInterfaceIterator>)getInterfaces:(NSError **)error {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) {
        os_log_error(MorkeTunnelLog(), "[sing-box] getInterfaces: getifaddrs failed: %{public}s", strerror(errno));
        return [[EXTNetworkInterfaceIterator alloc] initWithInterfaces:@[]];
    }

    // Group CIDR address strings per interface name.
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *addrsByName =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *flagsByName = [NSMutableDictionary dictionary];

    NSString *myTUN = self.myInterfaceName; // exclude our own TUN

    for (struct ifaddrs *ifa = addrs; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name) continue;
        const char   *cname = ifa->ifa_name;
        unsigned int  flags = ifa->ifa_flags;

        if (!morke_is_physical_interface(cname, flags)) continue;

        NSString *name = [NSString stringWithUTF8String:cname];
        if (myTUN.length && [name isEqualToString:myTUN]) continue;

        if (flagsByName[name] == nil) flagsByName[name] = @(flags);
        if (!addrsByName[name]) addrsByName[name]  = [NSMutableArray array];

        if (!ifa->ifa_addr) continue;
        int af = ifa->ifa_addr->sa_family;

        if (af == AF_INET) {
            char buf[INET_ADDRSTRLEN];
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;

            int prefix = morke_ipv4_netmask_prefix(ifa->ifa_netmask);
            [addrsByName[name] addObject:[NSString stringWithFormat:@"%s/%d", buf, prefix]];

        } else if (af == AF_INET6) {
            // sin6_addr starts at byte offset 8 of the sockaddr (xnu ABI); compute
            // it here for the inet_ntop call below. The offset-8 + fe80 parse lives
            // in MorkeTunnelNetHelpers (morke_ipv6_is_link_local). Avoid including
            // <netinet6/in6.h> (private module).
            const uint8_t *addrBytes = (const uint8_t *)ifa->ifa_addr + 8;
            // Skip link-local (fe80::/10)
            if (morke_ipv6_is_link_local(ifa->ifa_addr)) continue;

            char buf[INET6_ADDRSTRLEN];
            if (!inet_ntop(AF_INET6, addrBytes, buf, sizeof(buf))) continue;

            int prefix = morke_ipv6_netmask_prefix(ifa->ifa_netmask);
            [addrsByName[name] addObject:[NSString stringWithFormat:@"%s/%d", buf, prefix]];
        }
    }
    freeifaddrs(addrs);

    NSMutableArray<LibboxNetworkInterface *> *result = [NSMutableArray array];
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0); // for SIOCGIFMTU

    for (NSString *name in addrsByName) {
        const char *cname = name.UTF8String;

        LibboxNetworkInterface *iface = [[LibboxNetworkInterface alloc] init];
        iface.name  = name;
        iface.index = (int32_t)if_nametoindex(cname);
        iface.flags = [flagsByName[name] intValue];
        switch (morke_interface_type_for_name(cname)) {
            case MorkeInterfaceTypeWIFI:     iface.type = LibboxInterfaceTypeWIFI;     break;
            case MorkeInterfaceTypeCellular: iface.type = LibboxInterfaceTypeCellular; break;
            default:                         iface.type = LibboxInterfaceTypeOther;    break;
        }

        if (sockfd >= 0) {
            struct ifreq ifr;
            memset(&ifr, 0, sizeof(ifr));
            strncpy(ifr.ifr_name, cname, IFNAMSIZ - 1);
            iface.mtu = (ioctl(sockfd, SIOCGIFMTU, &ifr) == 0) ? ifr.ifr_mtu : 1500;
        } else {
            iface.mtu = 1500;
        }

        iface.addresses = [[EXTStringIterator alloc] initWithStrings:addrsByName[name]];
        [result addObject:iface];
    }
    if (sockfd >= 0) close(sockfd);

    os_log(MorkeTunnelLog(), "[sing-box] getInterfaces: %lu interface(s)", (unsigned long)result.count);
    return [[EXTNetworkInterfaceIterator alloc] initWithInterfaces:result];
}

- (BOOL)startNeighborMonitor:(id<LibboxNeighborUpdateListener>)listener
                       error:(NSError **)error {
    return YES;
}

- (BOOL)closeNeighborMonitor:(id<LibboxNeighborUpdateListener>)listener
                       error:(NSError **)error {
    return YES;
}

// Store the TUN interface name so getInterfaces: can exclude it.
- (void)registerMyInterface:(NSString *)name {
    self.myInterfaceName = name;
}

// MARK: - LibboxPlatformInterface — network state

- (BOOL)underNetworkExtension { return YES; }

// Report the REAL includeAllNetworks the OS is enforcing, read from the tunnel profile, instead of a
// hardcoded NO (T-CFG-17). sing-box uses this solely to SELECT the TUN stack: includeAllNetworks=YES
// forces the gVisor stack — the system/mixed stack is rejected under includeAllNetworks (libbox
// tun.NewStack → ErrIncludeAllNetworks). The app pairs this by rewriting the config's TUN stack to gVisor
// whenever the kill switch (includeAllNetworks) is on (SingBoxKillSwitchStack), so the engine's stack
// choice and the OS policy always agree. With the kill switch OFF this returns NO — identical to the
// previous hardcoded value, so the KS-OFF path is byte-for-byte unchanged. self.provider is weak;
// messaging nil safely yields NO. includeAllNetworks is an NEVPNProtocol property (iOS 14+).
- (BOOL)includeAllNetworks {
    return self.provider.protocolConfiguration.includeAllNetworks;
}

- (void)clearDNSCache {}
- (nullable LibboxWIFIState *)readWIFIState { return nil; }

// MARK: - LibboxPlatformInterface — notifications & certificates

- (BOOL)sendNotification:(LibboxNotification *)notification error:(NSError **)error {
    return YES;
}
- (nullable id<LibboxLocalDNSTransport>)localDNSTransport { return nil; }
- (nullable id<LibboxStringIterator>)systemCertificates   { return nil; }

// MARK: - LibboxPlatformInterface — shell / SSH stubs (iOS: not applicable)

- (NSString *)lookupSFTPServer:(NSError **)error { return @""; }

- (nullable LibboxPlatformUser *)lookupUser:(nullable NSString *)username
                                      error:(NSError **)error {
    return nil;
}

- (nullable id<LibboxShellSession>)openShellSession:(nullable LibboxPlatformUser *)user
                                            command:(nullable NSString *)command
                                            environ:(nullable id<LibboxStringIterator>)environ
                                               term:(nullable NSString *)term
                                               rows:(int32_t)rows
                                               cols:(int32_t)cols
                                              error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:20
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                @"shell sessions not supported on iOS"}];
    }
    return nil;
}

- (NSString *)readSystemSSHHostKey:(NSError **)error { return @""; }
- (NSString *)tailscaleHostname { return @""; }

// MARK: - LibboxCommandServerHandler — service lifecycle

- (BOOL)serviceStop:(NSError **)error {
    // sing-box asked us to tear the tunnel down. serviceStop fires on BOTH a clean
    // engine shutdown and a FATAL error inside the engine, and libbox does not tell us
    // which. Report the stop to the NE session with a descriptive NSError (not nil) so
    // an engine-requested stop is distinguishable from a clean user disconnect in
    // Console / NE post-mortems — passing nil records it as a clean stop and hides the
    // cause. (The (NSError **)error out-param is libbox's "serviceStop itself failed"
    // channel; we succeed here, so it stays untouched — this is a separate error.)
    //
    // Intent: this NSError is a benign CLASSIFICATION marker only. It must NOT read as a
    // permanent failure. iOS on-demand rules re-evaluate independently of the stop error,
    // so a descriptive error here does not suppress the kill-switch crash-gap re-raise
    // (engine-fatal under includeAllNetworks → interim blocked → on-demand re-raise).
    // That re-raise is verified on device under T-REL-2, not asserted here. (Mirrors the
    // sing-box-for-apple reference, which likewise passes a non-nil error.)
    NSError *stopError =
        [NSError errorWithDomain:kMorkeTunnelErrorDomain code:30
                        userInfo:@{NSLocalizedDescriptionKey:
                                       @"sing-box engine requested stop (engine-fatal)"}];
    [self.provider cancelTunnelWithError:stopError];
    return YES;
}

- (BOOL)serviceReload:(NSError **)error { return YES; }

// MARK: - LibboxCommandServerHandler — system proxy (no-op on iOS)

- (BOOL)setSystemProxyEnabled:(BOOL)enabled error:(NSError **)error { return YES; }

- (nullable LibboxSystemProxyStatus *)getSystemProxyStatus:(NSError **)error {
    return [[LibboxSystemProxyStatus alloc] init];
}

// MARK: - LibboxCommandServerHandler — debug / SSH agent stubs

- (void)writeDebugMessage:(nullable NSString *)message {
    // sing-box debug output can carry outbound endpoints / DNS / sniffed SNI / 5-tuples.
    // Never emit it in Release (no-logs posture); in Debug log it %{private} so it stays
    // redacted in the unified log unless a logging configuration profile is installed.
#if DEBUG
    if (message.length > 0) {
        os_log_debug(MorkeTunnelLog(), "[sing-box][dbg] %{private}@", message);
    }
#endif
}

- (BOOL)connectSSHAgent:(int32_t *)ret0_ error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:kMorkeTunnelErrorDomain code:21
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                @"SSH agent not supported on iOS"}];
    }
    return NO;
}

- (BOOL)triggerNativeCrash:(NSError **)error { return YES; }

@end
