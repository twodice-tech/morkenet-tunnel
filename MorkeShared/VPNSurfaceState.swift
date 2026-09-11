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

// MARK: - VPNSurfaceStatus
//
// The tunnel's connection state as the OUT-OF-APP surfaces see it (T-EXT-0). Raw values mirror
// NEVPNStatus exactly, and that mirroring is deliberate rather than lazy:
//
//   MorkeShared's contract is Foundation + Security + CryptoKit and NOTHING else — it is linked
//   into MorkeTunnel.appex, whose memory tier is the tightest budget in the tree. Importing
//   NetworkExtension here to name one enum would widen that contract for a type that is only ever
//   written as an integer to a file. The mapping is instead asserted by a test that DOES import
//   NetworkExtension (VPNSurfaceStateTests), so a raw value can never drift unnoticed — the same
//   "one derivation, one place, one test" discipline the key fingerprint uses.
//
// It is also what lets a widget or Control Center extension read the whole surface by linking
// MorkeShared ALONE, which has zero package dependencies. Any richer home (MorkeModels pulls in
// swift-sharing; MorkeServices pulls in swift-dependencies) would make the smallest consumer of
// this file pay for a dependency graph it has no other use for.

public enum VPNSurfaceStatus: Int, Codable, Sendable, Equatable {
    case invalid       = 0
    case disconnected  = 1
    case connecting    = 2
    case connected     = 3
    case reasserting   = 4
    case disconnecting = 5
}

// MARK: - VPNSurfaceWidget
//
// The widget's `kind`. It lives HERE, in the app↔extension surface, because since T-EXT-1 it is a
// name THREE processes must agree on: the widget declares it, the app reloads it after a publish,
// and the tunnel extension reloads it when it stops. A string only some of them know is a string
// that silently stops matching, and nothing would fail loudly when it does.
//
// `controlKind` joined it in T-EXT-3 for exactly the same reason, and it is NOT decoration. A
// Control Center control has no timeline: measured on 2026-09-09, opening Control Center does not
// re-read the control's value, so the ONLY things that refresh it are an interaction with the
// control itself and an explicit `ControlCenter.reloadControls(ofKind:)`. Without the same two
// callers reloading this name, a control that renders on/off state would show whatever it showed
// when it was last touched — forever. See MorkeWidget/ProtectionControl.swift.
//
// ⚠️ `controlKind` NAMES THE TEMPLATE TYPE ON PURPOSE, and that is a working rule rather than a
// label. The system archives a control's GALLERY PREVIEW in a file keyed by this string, inside the
// widget extension's own data container — which survives an app update. Change the template under an
// unchanged key and the archive stops matching: the placed control still renders (the extension
// draws it live) while the "Add a Control" gallery shows an EMPTY CIRCLE that no reinstall clears.
// That happened once, on 2026-09-09, going from `ControlWidgetButton` to `ControlWidgetToggle` under
// `MorkeProtectionControl`. Keeping the type IN the name makes the next such change impossible to
// make silently: a button would have to be called `MorkeProtectionButton`, which is a new key, which
// is exactly the bump the situation requires. Full post-mortem: ProtectionControl.swift.

public enum VPNSurfaceWidget {
    public static let kind = "MorkeProtectionWidget"
    public static let controlKind = "MorkeProtectionToggle"
}

// MARK: - VPNSurfaceState
//
// The ONE thing every out-of-app surface reads (T-EXT-0): a small JSON document in the App-Group
// container carrying the connection state, which node it is about, and the last ping we measured
// for that node. Widget, Control Center control and Shortcuts all read this and nothing else, so
// they cannot disagree with each other — and none of them needs to touch NetworkExtension, which
// they could not use anyway (see ToggleVPNIntent's header for why).
//
// ⚠️ WHAT MAY NOT GO IN HERE, and the rule is absolute. This is an unencrypted file on disk in a
// container every one of our processes can read. The activation key, the JWT, the device
// credential and the sing-box config are secrets and NONE of them may appear — they live in the
// shared Keychain and stay there (CLAUDE.md § Constraints). A node's name, country and ISO code
// are not secrets: they are the same values `GET /api/v1/nodes` serves to anyone with an account,
// and they are already on screen. The node's IP is deliberately ALSO absent — not because it is
// secret, but because no surface needs it, and the smallest blob that does the job is the one that
// cannot leak something later.
//
// `capturedAt` is the honesty mechanism, not decoration. Nothing outside the app process can
// observe NEVPNStatus (the NE preferences are owned by the app that created them), so a tunnel
// raised by an on-demand rule while the app was not running leaves this file saying whatever the
// app last wrote. A surface that renders `capturedAt` — or simply refuses to assert freshness —
// tells the truth; one that assumes the blob is live does not.

public struct VPNSurfaceState: Codable, Sendable, Equatable {
    public var status: VPNSurfaceStatus
    // The OS-tracked connection start (NEVPNConnection.connectedDate), so a surface can render
    // "protected for N" without keeping its own clock. nil whenever the tunnel is not up.
    public var connectedSince: Date?
    // The node this state is ABOUT — the pinned selection, or the node auto-select resolved to.
    // nil while the user is on Auto-select and nothing has resolved yet.
    public var nodeId: Int?
    public var nodeName: String?
    public var country: String?
    // ISO 3166-1 alpha-2, the key FlagView already renders from. Carried rather than derived so a
    // surface needs no node list of its own.
    public var countryCode: String?
    // Last measured latency for `nodeId`, floor milliseconds — the SAME derivation the sheet uses.
    // Measurement only runs while the tunnel is down (a VPN-routed probe measures the tunnel, not
    // the node), so this is by construction a LAST-KNOWN value and never a live one. Widgets must
    // not probe; that is the whole reason it is carried here.
    public var pingMilliseconds: Int?
    // When this document was written. See the header: it is what separates "the tunnel is up" from
    // "the app last saw the tunnel up".
    public var capturedAt: Date

    public init(
        status: VPNSurfaceStatus,
        connectedSince: Date? = nil,
        nodeId: Int? = nil,
        nodeName: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        pingMilliseconds: Int? = nil,
        capturedAt: Date
    ) {
        self.status = status
        self.connectedSince = connectedSince
        self.nodeId = nodeId
        self.nodeName = nodeName
        self.country = country
        self.countryCode = countryCode
        self.pingMilliseconds = pingMilliseconds
        self.capturedAt = capturedAt
    }
}

// MARK: - App-Group store
//
// Same shape and the same fail-closed bias as the on-demand re-arm intent above it in AppGroup:
// an injectable `container` seam falling back to the resolved App-Group container, best-effort
// writes that cannot throw into a caller with no way to act on the error, and a read that answers
// NOTHING rather than something wrong.
//
// FAIL-CLOSED HERE MEANS `nil`, and `nil` must mean "unknown" at every call site — never
// "disconnected". A surface that renders a missing blob as "off" is asserting a fact it does not
// have; one that renders it as "open Morke" is telling the truth. The unresolvable container
// (no entitlement, off device), the absent file and the undecodable file all collapse to that one
// answer on purpose: none of them is evidence about the tunnel.
//
// NOT `#if os(iOS)`-walled, and the reason is exactly T-CFG-53's for the re-arm intent: the
// restriction that governs this container was never about resolving it, it was about using it as
// an app↔SYSTEM-EXTENSION channel, which macOS cannot do (containerURL resolves per user and the
// sysext runs as root — see AppGroup's header). Nothing here crosses that boundary; the only
// writer is the app process and the only readers are iOS app extensions, which run as the user.
// Leaving the helpers platform-neutral is also what lets the macOS-hosted test target exercise
// them at all. What IS iOS-scoped is the PUBLISHING (VPNSurfacePublisher), because the surfaces
// that consume this are iOS-only and the macOS section is paused.

extension AppGroup {

    private static let vpnSurfaceStateName = "vpn-surface-state.json"

    private static func vpnSurfaceStateURL(_ container: URL) -> URL {
        container.appendingPathComponent(vpnSurfaceStateName)
    }

    // Best-effort, atomic. Atomic because a surface reading a half-written file would decode to
    // nil and blink to "unknown" for no reason; best-effort because a write failure degrades to a
    // stale-but-valid document, which `capturedAt` already makes legible, and no caller could do
    // anything with the error.
    public static func writeVPNSurfaceState(_ state: VPNSurfaceState, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: vpnSurfaceStateURL(container), options: .atomic)
    }

    // nil for every failure — see the fail-closed note above.
    public static func readVPNSurfaceState(container: URL? = nil) -> VPNSurfaceState? {
        guard let container = container ?? defaultContainer() else { return nil }
        guard let data = try? Data(contentsOf: vpnSurfaceStateURL(container)) else { return nil }
        return try? JSONDecoder().decode(VPNSurfaceState.self, from: data)
    }

    // Read-modify-write for the ONE caller that knows the status but not the node — the toggle
    // intent, which may run in a freshly launched background app process with no UI state at all.
    // Preserving the node/ping half is what keeps a widget-initiated connect from blanking the
    // server name the widget is displaying. Single-process by construction (the intent runs in the
    // app's process, never a widget's), so the read and the write cannot interleave across
    // processes; an in-process interleave costs one field for one write and is corrected by the
    // next publish.
    public static func updateVPNSurfaceState(
        container: URL? = nil,
        _ mutate: (inout VPNSurfaceState) -> Void
    ) {
        var state = readVPNSurfaceState(container: container)
            ?? VPNSurfaceState(status: .invalid, capturedAt: .distantPast)
        mutate(&state)
        writeVPNSurfaceState(state, container: container)
    }

    // Removes the document. Called from TunnelWorkspace.wipe(), so a sign-out or a Reset VPN
    // profile leaves no surface still naming the node the previous account connected to. A missing
    // file is a no-op — wipe() must never throw or block sign-out.
    public static func clearVPNSurfaceState(container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? FileManager.default.removeItem(at: vpnSurfaceStateURL(container))
    }
}
