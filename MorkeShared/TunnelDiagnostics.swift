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

// MARK: - TunnelDiagnostics (T-INFRA-27)
//
// The app↔extension half of the connection report built to converge T-INFRA-26 (nothing reaches
// the backend over Russian mobile data) in ONE round instead of three. KEPT as a permanent
// developer tool (T-INFRA-28), and deliberately narrow: it answers one question, so do not build on
// it, do not extend it, do not give it a second caller. Its reach is the point — half of this file
// is the argument for why nothing else may pass through it.
//
// Two pieces, both about OUR OWN process and nothing else:
//
//   1. `State` — what the app asks the running extension for over
//      NETunnelProviderSession.sendProviderMessage. Three facts, deliberately: the provider side
//      must stay trivial, because it runs inside the Packet-Tunnel memory budget.
//
//   2. The EVENT RING — a bounded file of our own extension lifecycle events in the App-Group
//      container, so an extension that already died still leaves a trace. sendProviderMessage can
//      only ever reach a LIVE extension; the ring is what covers the case that matters most.
//
// PRIVACY — the line this must not cross. The ring records a CLOSED SET of our own event names plus
// an optional INTEGER, and nothing else. That is structural, not a convention: `Event` is an enum
// and `detail` is an `Int?`, so there is no way to smuggle a hostname, an address, or a destination
// through this API even by accident. It is the same line `SingBoxConfigValidator` defends by
// refusing sing-box's `log.output`, and being convenient is not a reason to cross it.
//
// PLATFORM. Meaningful on iOS. On macOS the app and the system extension resolve DIFFERENT
// App-Group containers (the sysext runs as root — see AppGroup.macOSAuthenticatedKey), so a ring
// written from the macOS extension is never read by the macOS app. The code is platform-neutral on
// purpose — it is plain file I/O, which keeps it unit-testable on the macOS test host with an
// injected container — but the macOS app's report says the ring is unavailable rather than
// pretending an empty file means "no events".
public nonisolated enum TunnelDiagnostics {

    // MARK: - App → extension message

    // The ONE request the extension answers. Any other payload is ignored (nil response), so this
    // channel cannot be repurposed into a general-purpose command surface by accident.
    public static let stateRequest = "morke.diagnostics.state"

    // What the extension reports back, JSON-encoded. Everything here is about the extension's own
    // process: whether an engine object exists, when the start was accepted, and how many BYTES the
    // config was — never the config, never a destination, never a credential.
    public struct State: Codable, Sendable, Equatable {
        public var running: Bool
        public var startedAt: Date?
        public var configBytes: Int?

        public init(running: Bool, startedAt: Date?, configBytes: Int?) {
            self.running = running
            self.startedAt = startedAt
            self.configBytes = configBytes
        }
    }

    // MARK: - Extension event ring

    // The closed set. Adding a case is a deliberate act; adding a free-form string is not possible.
    public enum Event: String, Sendable {
        case startRequested             = "start-requested"
        case startRefusedNotAuthorized  = "start-refused-not-authorized"
        case startRefusedMissingConfig  = "start-refused-missing-config"
        case startSucceeded             = "start-succeeded"
        case startFailed                = "start-failed"
        case stopped                    = "stopped"
        case slept                      = "slept"
        case woke                       = "woke"
    }

    public struct EventRecord: Sendable, Equatable {
        public var date: Date
        public var event: String
        public var detail: Int?

        public init(date: Date, event: String, detail: Int?) {
            self.date = date
            self.event = event
            self.detail = detail
        }
    }

    // Bounded by construction — 40 lines of at most ~60 characters is ~2.5 KB, which is what makes
    // the whole-file rewrite below acceptable inside the NE budget and keeps the pasted report small.
    public static let ringCapacity = 40

    private static let ringName = "diagnostic-events"

    // Local copy of AppGroup's private container resolver. Duplicated rather than widening
    // AppGroup's API, so deleting this file deletes the whole feature.
    private static func defaultContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.appGroupID)
    }

    // Called from the extension only. Best-effort (`try?`, never throws): a lost event costs one
    // line of a diagnostic, and a pre-first-unlock on-demand start legitimately cannot write at all
    // (App-Group file protection matches the Keychain items the start gate already fails on).
    //
    // Read-modify-write of the whole file, which is safe here because the APP never writes — it only
    // reads — so there is exactly one writer process. `detail` carries a byte count or an
    // NEProviderStopReason raw value; it is an Int so it can carry nothing else.
    public static func record(_ event: Event, detail: Int? = nil, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        let url = container.appendingPathComponent(ringName)
        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        if let detail {
            lines.append("\(Date().timeIntervalSince1970) \(event.rawValue) \(detail)")
        } else {
            lines.append("\(Date().timeIntervalSince1970) \(event.rawValue)")
        }
        if lines.count > ringCapacity {
            lines.removeFirst(lines.count - ringCapacity)
        }
        try? Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    // Called from the app only. An unresolvable container, a missing file and a malformed line all
    // degrade to "fewer records", never to a throw — this is a diagnostic, not a gate.
    public static func readEvents(container: URL? = nil) -> [EventRecord] {
        guard let container = container ?? defaultContainer() else { return [] }
        let url = container.appendingPathComponent(ringName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let seconds = Double(parts[0]) else { return nil }
            return EventRecord(
                date: Date(timeIntervalSince1970: seconds),
                event: String(parts[1]),
                detail: parts.count >= 3 ? Int(parts[2]) : nil
            )
        }
    }
}
