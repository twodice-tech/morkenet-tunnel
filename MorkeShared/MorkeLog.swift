// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Two Dice Ltd
//
// DUAL-LICENSED — this is our own code and it ships inside two different works.
// Both paragraphs are true at once; neither alone is the position.
//
//   • In MorkeTunnel.appex, which statically links sing-box
//     (https://github.com/SagerNet/sing-box, GPL-3.0-or-later), GPLv3 § 5(c)
//     licenses that entire work as a whole under the GPL. Everyone who receives
//     this file — from the shipped extension, or from the published tunnel-source
//     repository — receives it under the GNU General Public License v3 or later,
//     on the terms below. That grant is unconditional and nothing in this header
//     narrows it.
//
//   • In Morke.app, the closed-source client, which links no GPL-licensed code.
//     As the copyright holder we additionally license this same file under our own
//     proprietary terms for that use. Nothing here places Morke.app, or any other
//     MorkeKit module, under the GPL.
//
// Dual-licensing our own code is ordinary and deliberate, and it does not take back
// the grant above: a recipient may use this file under the GPL for anything the GPL
// allows. A blanket "this file is GPLv3" would be inaccurate in the other direction,
// and a blanket "this file is proprietary" would be inaccurate in this one.
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

import Foundation

// Canonical os_log subsystem for every target that links MorkeShared directly (MorkeServices,
// MorkeTunnel). Mirrors the `tech.twodice.morke` namespace documented in
// SharedKeychain.swift:13-17 (bundle id · App Group · os_log subsystem).
//
// MorkeFeatures (App/FeatureLog.swift) and MorkeGlobe (GlobeLog.swift) deliberately do NOT
// depend on MorkeShared (Package.swift's dependency-graph comments), so each keeps its OWN
// module-local mirror of this same string; the ObjC `os_log_create` call in
// MorkeTunnel/ExtensionPlatformInterface.m is a fourth, independent mirror. All four MUST stay
// byte-identical — renaming one but not the others silently splits the Console.app / os_log
// filter namespace the device smoke-test relies on, with no compile error (same failure shape
// as the SharedKeychain.swift:16-17 warning).
public enum MorkeLog {
    // nonisolated: read from actor-isolated call sites (VPNCore, AppAttestCoordinator,
    // ConfigCache) as well as MainActor ones. Immutable Sendable value, so opting out of
    // actor isolation is safe.
    public nonisolated static let subsystem = "tech.twodice.morke"
}
