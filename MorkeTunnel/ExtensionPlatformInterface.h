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

#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

// Suppress warnings that originate in gobind-generated Libbox headers:
// • -Wnullability: conflicting nullable/nonnull specifiers on -init overrides
// These are upstream gobind artifacts unrelated to our code.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability"
@import Libbox;
#pragma clang diagnostic pop

NS_ASSUME_NONNULL_BEGIN

/// Bridges the sing-box engine (libbox) to iOS Network Extension APIs.
/// Conforms to LibboxPlatformInterface (TUN setup, interface monitoring, process info)
/// and LibboxCommandServerHandler (service lifecycle, system proxy, debug).
///
/// All protocol methods are called from Go goroutines (arbitrary C threads).
/// The MorkeTunnel target omits SWIFT_DEFAULT_ACTOR_ISOLATION so methods run
/// on the calling thread without actor-isolation violations.
@interface ExtensionPlatformInterface : NSObject <LibboxPlatformInterface, LibboxCommandServerHandler>

- (instancetype)initWithProvider:(NEPacketTunnelProvider *)provider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Cancel the NWPathMonitor and drop the provider reference.
/// Must be called before releasing the LibboxCommandServer on stop.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
