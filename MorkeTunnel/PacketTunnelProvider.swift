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

import NetworkExtension
import OSLog
import WidgetKit
import MorkeShared

// os_log destination for all Network Extension lifecycle events.
// Console.app filter: Subsystem = "tech.twodice.morke", Category = "tunnel"
private let log = Logger(subsystem: MorkeLog.subsystem, category: "tunnel")

// @objc name is pinned so NSExtensionPrincipalClass = "PacketTunnelProvider" in Info.plist
// resolves correctly regardless of Swift module name changes (T-RENAME-1).
@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {

    // SingBoxTunnel is created lazily inside startTunnel, not as a stored property.
    // Best practice: avoid touching the Go runtime during class initialisation.
    // Note: the NE launch crash on iOS 26.5 was NOT caused by eager libbox —
    // root cause was missing CFBundlePackageType = XPC! in Info.plist.
    // See docs/singbox-integration.md § "No libbox in principal init".
    private var singBox: SingBoxTunnel?

    // T-INFRA-27: when this process accepted a start, so the app can report an uptime. Written and
    // read on the provider queue only.
    private var startedAt: Date?
    // T-INFRA-27: size of the config this start ran, in BYTES. Never the config.
    private var configBytes: Int?
    // T-UX-7: the measurement base for this session's length, on a MONOTONIC axis rather than the
    // wall clock. `startedAt` above cannot serve — it is a `Date`, so an NTP correction or a user
    // clock change mid-session would be folded straight into a lifetime total the user could only
    // repair by resetting it. `ContinuousClock` keeps running across system sleep, which is exactly
    // what a tunnel that stays up overnight needs, and a reboot (which would reset the axis) also
    // kills this process, so no session can span one. It is not a timestamp: an instant on an
    // arbitrary monotonic axis says nothing about when anything happened, and it never leaves
    // memory. Written and read on the provider queue only, like the two above.
    private var startedAtMonotonic: ContinuousClock.Instant?

    override init() {
        log.notice("PacketTunnelProvider: init")
        super.init()
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice("startTunnel: requested")
        // T-INFRA-27: our own lifecycle events into the bounded App-Group ring, so an extension
        // that dies before the app can ask it anything still leaves a trace. Closed event set + an
        // optional Int by construction — nothing about traffic can pass through it.
        TunnelDiagnostics.record(.startRequested)

        // Authorization guard.
        #if os(macOS)
        // macOS: this system extension is SANDBOXED and runs AS ROOT in the system context, not the user
        // session — so it shares NEITHER of the two stores the iOS appex reads. The user keychain returns
        // errSecNotAvailable, and containerURL(forSecurityApplicationGroupIdentifier:) resolves PER USER,
        // so the App-Group container reached from here is root's (/var/root/Library/Group Containers/…)
        // and never the one the app writes as the console user. providerConfiguration, which the OS
        // itself hands to this process, is therefore the ONLY app→extension channel on macOS, and this
        // single flag is the whole gate. (T-MAC-10 required a SECOND signal — an App-Group presence
        // marker — which for that reason could never be found: the gate failed closed on every connect
        // and the Mac tunnel could not start at all. T-MAC-14 removed it and made the CLEARING of this
        // flag reliable instead.)
        //
        // The fail-open this must still refuse: sign-out's removeProfile() is best-effort, so a throw
        // would leave the saved profile carrying both this flag and the live VLESS config, re-raisable by
        // a later network event for a signed-out user. VPNCore.removeProfile() now closes that in-place —
        // when removeFromPreferences throws it strips this key AND the stored config from the saved
        // providerConfiguration — so a start reached that way arrives with the flag gone and stops here.
        guard
            let authProto = protocolConfiguration as? NETunnelProviderProtocol,
            authProto.providerConfiguration?[AppGroup.macOSAuthenticatedKey] as? Bool == true
        else {
            log.error("startTunnel: failed — not authenticated (macOS providerConfiguration auth flag absent)")
            refuseStart(.notAuthorized, completionHandler)
            return
        }
        #else
        // Authorization guard: require a non-empty activation key in Keychain that MATCHES the config
        // this start is about to run (T-CFG-45, second guard below).
        // On on-demand reconnect (no app running) the OS re-delivers the stored
        // providerConfiguration, so the key is read directly — no app wake needed.
        //
        // do/catch (not try?) so a transient keychain failure — e.g. errSecInteractionNotAllowed on
        // a pre-first-unlock on-demand start — surfaces its distinct OSStatus instead of collapsing
        // into the same "key absent" line as a genuinely-missing key (L5). Log only the numeric
        // status + a generic message: never the key, its presence, or its value.
        do {
            guard
                let key = try SharedKeychain.loadActivationKey(),
                !key.isEmpty
            else {
                log.error("startTunnel: failed — activation key absent from Keychain")
                refuseStart(.notAuthorized, completionHandler)
                return
            }
            // T-CFG-45: presence is not enough — require the key to be THE key this config was saved
            // for. The app writes SHA-256(activation key) into the App-Group container at connect time,
            // right before it saves the providerConfiguration read below (VPNCore.connect), so a
            // mismatch means the installed config belongs to a different account than the one now in
            // the Keychain — exactly what an involuntary session expiry followed by a login with
            // another key produces (T-AUTH-19 retains both the key and the profile), and what a
            // presence-only marker would wave through. Absent / unreadable digest ⇒ no match ⇒ refuse.
            // Generic log line only: never the key, the digest, the account, or the config.
            guard AppGroup.iOSKeyFingerprintMatches(key) else {
                log.error("startTunnel: failed — activation key does not match the installed configuration")
                refuseStart(.notAuthorized, completionHandler)
                return
            }
        } catch SharedKeychainError.unexpectedStatus(let status) {
            log.error("startTunnel: failed — keychain read error (OSStatus \(status, privacy: .public))")
            refuseStart(.notAuthorized, completionHandler)
            return
        } catch {
            log.error("startTunnel: failed — keychain read error")
            refuseStart(.notAuthorized, completionHandler)
            return
        }
        #endif

        // Config guard. The app stores the config before every connect (see VPNManagerClient.connect);
        // on an on-demand reconnect there is no app process, so whatever it stored last is what runs.
        // WHERE it is stored is per-platform and NOT a preference — see below.
        #if os(iOS)
        // T-CFG-41: the bytes live in the SHARED KEYCHAIN and providerConfiguration carries only a
        // non-secret marker, because the config is a live proxy credential (per-account VLESS UUID +
        // REALITY params) and NE preferences are unencrypted for as long as the profile is installed.
        //
        // Marker first: absent means this profile was not saved by a build that stores the config here —
        // an install upgraded across T-CFG-41, whose stale providerConfiguration bytes are deliberately
        // NOT read. It refuses the start; the next in-app connect re-fetches, stores, and replaces
        // providerConfiguration with the marker alone. Distinct log line from a missing store, which is
        // the whole reason the marker exists.
        guard AppGroup.expectsKeychainConfig(
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        ) else {
            log.error("startTunnel: failed — profile does not expect a stored config (connect from the app once)")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        // The store is a CACHE, never the only copy (Q34): a missing or unreadable item FAILS THE START
        // CLOSED here and is repaired by an ordinary foreground connect — which is also what has to heal
        // the go-live REALITY rotation (B-SAFE-3, one announced rotation with no grace window). No
        // re-fetch is attempted from here, deliberately: an on-demand raise has no app process and
        // possibly an expired JWT, so a fetch would fail exactly when the tunnel matters most.
        //
        // do/catch (not try?) so a transient keychain failure — e.g. errSecInteractionNotAllowed on a
        // pre-first-unlock on-demand start — surfaces its OSStatus instead of collapsing into the same
        // line as a genuinely-absent config, mirroring the activation-key read above. That pre-first-
        // unlock case is NOT new: the key read above already fails there, and both items share
        // SharedKeychain.accessibility, so the two become unavailable together, never apart.
        let configData: Data
        do {
            guard let stored = try SharedKeychain.loadTunnelConfig() else {
                log.error("startTunnel: failed — no stored sing-box config (connect from the app to restore it)")
                refuseStart(.missingConfig, completionHandler)
                return
            }
            configData = stored
        } catch SharedKeychainError.unexpectedStatus(let status) {
            log.error("startTunnel: failed — sing-box config keychain read error (OSStatus \(status, privacy: .public))")
            refuseStart(.missingConfig, completionHandler)
            return
        } catch {
            log.error("startTunnel: failed — sing-box config keychain read error")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        guard
            let configJSON = String(data: configData, encoding: .utf8),
            !configJSON.isEmpty
        else {
            log.error("startTunnel: failed — stored sing-box config is empty or not UTF-8")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        #else
        // macOS: the bytes stay in providerConfiguration. NOT a leftover — this sysext is sandboxed and
        // runs AS ROOT, so SecItem returns errSecNotAvailable and the App-Group container it resolves is
        // root's, not the app's (T-MAC-14). providerConfiguration is the only channel the OS carries in.
        guard
            let proto       = protocolConfiguration as? NETunnelProviderProtocol,
            let configData  = proto.providerConfiguration?[AppGroup.singBoxConfigKey] as? Data,
            let configJSON  = String(data: configData, encoding: .utf8),
            !configJSON.isEmpty
        else {
            log.error("startTunnel: failed — sing-box config absent from provider profile")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        #endif

        // Log config size (bytes) only — never log the config content, keys, or JWT.
        log.notice("startTunnel: config received (\(configData.count, privacy: .public) bytes)")

        // SingBoxTunnel is created on the NE provider queue so singBox is safely written
        // before the background work begins. box.start is moved off the provider queue:
        // openTun calls setTunnelNetworkSettings whose completion is delivered back to
        // this queue — running start() here would deadlock (queue blocked waiting on itself).
        let box = SingBoxTunnel()
        singBox = box
        // T-INFRA-27: both set on the provider queue, before the handoff below, so the background
        // closure never mutates provider state off-queue.
        startedAt = Date()
        startedAtMonotonic = ContinuousClock.now
        configBytes = configData.count
        // `self` (the NE provider) and `completionHandler` are non-Sendable, but this is a single,
        // one-shot handoff onto the background queue: start() runs exactly once, `self` is used only
        // to bridge packet I/O through ExtensionPlatformInterface (NE-synchronised), and the handler
        // is invoked exactly once. There is no shared mutable state to race, so the narrow
        // nonisolated(unsafe) is warranted. The off-queue dispatch is mandatory — running start() on
        // the provider queue deadlocks (openTun → setTunnelNetworkSettings completes back on it).
        nonisolated(unsafe) let provider = self
        nonisolated(unsafe) let completion = completionHandler
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try box.start(configJSON: configJSON, provider: provider)
                log.notice("startTunnel: tunnel started successfully")
                TunnelDiagnostics.record(.startSucceeded, detail: configData.count)
                completion(nil)
            } catch {
                log.error("startTunnel: libbox start failed — \(error.localizedDescription, privacy: .public)")
                TunnelDiagnostics.record(.startFailed)
                // A thrown start can leave the engine half-up (command server, published
                // platformInterface, possibly applied TUN settings): the OS does NOT deliver
                // stopTunnel for a failed start, so run the deliberate closeService → reset → close
                // teardown here before reporting. box.stop() is idempotent / race-latched (M8).
                box.stop()
                completion(error)
            }
        }
    }

    // MARK: - Refusal delivery (T-CFG-52 measurement 2)
    //
    // Every guard above refuses through this ONE seam so the delivery STYLE can be varied without
    // touching a single gate. Default — and the only thing any shipping build compiles — is the
    // unchanged `completionHandler(error)`; the two variants exist for one question the maintainer set
    // as a done criterion: does the style change iOS's retry cadence? Neither variant is a candidate
    // fix. `cancelTunnelWithError(nil)` never calls the completion handler at all, and complete-then-stop
    // reports a tunnel that came up when it did not — it lies to the OS about the state of the
    // connection, which is exactly why it must be measured before anyone is tempted by it. Selected by
    // -D flags that no scheme and no xcconfig sets.
    //
    // KEPT after T-CFG-52 closed (maintainer, 2026-08-16). Measured answer, so nobody re-runs it: all
    // three styles produce the SAME ~20.3 s iOS cadence — the ceiling is Apple's, not the style's —
    // and complete-then-stop never reaches `.connected` at all, so it costs honesty and buys nothing.
    // Usage, build commands and the full numbers: Docs/reference/smoke-test.md § Device-verification
    // harness. **Adding a guard above means calling THIS seam**; a direct completionHandler call would
    // be silently skipped by every future style measurement.
    private func refuseStart(_ error: TunnelStartError, _ completionHandler: @escaping (Error?) -> Void) {
        // T-INFRA-27: every refusal is recorded here for the same reason every refusal is
        // DELIVERED here — one seam, so a future guard cannot forget either half.
        switch error {
        case .notAuthorized: TunnelDiagnostics.record(.startRefusedNotAuthorized)
        case .missingConfig: TunnelDiagnostics.record(.startRefusedMissingConfig)
        }
        #if MORKE_REFUSE_STYLE_CANCEL
        log.notice("refusal style: cancelTunnelWithError(nil), completion handler NEVER called (measurement 2)")
        cancelTunnelWithError(nil)
        #elseif MORKE_REFUSE_STYLE_COMPLETE_THEN_STOP
        log.notice("refusal style: completionHandler(nil) then cancelTunnelWithError(nil) — reports a tunnel that is NOT up (measurement 2)")
        completionHandler(nil)
        cancelTunnelWithError(nil)
        #else
        completionHandler(error)
        #endif
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.notice("stopTunnel: reason \(reason.rawValue, privacy: .public)")
        TunnelDiagnostics.record(.stopped, detail: reason.rawValue)
        singBox?.stop()
        singBox = nil
        publishStoppedToSurfaces()
        recordProtectedSession()
        // T-INFRA-27: startedAt / configBytes are deliberately NOT cleared. `running` already says
        // the engine is gone (it reads `singBox != nil`), and what the report needs from a live but
        // idle extension is WHEN the last tunnel ran in it — clearing them made the report say "no
        // tunnel started in it" directly above an event ring showing a start and a stop seconds
        // earlier, which is the one thing a diagnostic must never do (maintainer, 2026-08-17).
        completionHandler()
    }

    // MARK: - Telling the out-of-app surfaces the tunnel is down (T-EXT-1)
    //
    // ⚠️ THIS IS THE ONE PLACE THAT KNOWS. Device-found 2026-09-08: with the app swiped away, turning
    // the VPN off in Settings or Control Center left the widget counting a live timer — asserting
    // protection that did not exist — because the App-Group document is written only by the APP, and
    // a suspended app runs no NEVPNStatus observer. The log is unambiguous: `stopTunnel: reason 1` at
    // 18:22:38 with not one `Morke` line after it. Nothing on the widget's side can fix that; the
    // document is the only channel, and this process is the only witness left awake.
    //
    // WHY THIS CROSSES TWO RULES ON PURPOSE, both of them ours:
    //   • T-EXT-0 scoped extension-publishing OUT, and VPNSurfacePublisher's header still records the
    //     consequence it accepted. The consequence turned out to be worse in the STOP direction than
    //     the header imagined for the START one — a stale "connected" is not a surface lagging, it is
    //     a VPN telling someone they are protected when they are not.
    //   • The appex's link set is audited to MorkeShared alone under a memory tier whose enforced
    //     metric is unresolved (T-CFG-16). `AppGroup` is already in MorkeShared, so the WRITE adds no
    //     link; `WidgetCenter` does add WidgetKit, and that was taken as a measured decision against a
    //     baseline of 16.5–21.2 MiB for this process (five Activity Monitor windows, 2026-09-08) —
    //     not as an assumption that a system framework is free. If the number moved, the reload goes
    //     and the widget polls for it instead.
    //
    // Deliberately narrow: status and connection start only. This process knows neither node nor
    // ping, and `updateVPNSurfaceState` merges, so the widget keeps showing the server it had.
    // Best-effort by construction — stopTunnel is on a deadline and nothing here may block it.
    private func publishStoppedToSurfaces() {
        AppGroup.updateVPNSurfaceState { state in
            state.status = .disconnected
            state.connectedSince = nil
            state.capturedAt = Date()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: VPNSurfaceWidget.kind)
        // T-EXT-3: the Control Center control has no timeline at all, so this is the only thing that
        // can take its switch down when a VPN is stopped from outside the app. Same framework, no new
        // link, same best-effort caveat as the line above — and the same known residual, that this
        // XPC is sent from a process the system is tearing down and does not always land.
        //
        // ⚠️ `#if os(iOS)` AND NOT ONLY `#available`, because this file builds twice. `ControlCenter`
        // is iOS 18 / macOS 26, and the macOS system extension deploys to macOS 14 — an availability
        // check alone fails the Mac build outright, which is how this line was caught. There is
        // nothing to reload there in any case: the surfaces are iOS-only (VPNSurfacePublisher's
        // header) and the T-MAC section is paused.
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: VPNSurfaceWidget.controlKind)
        }
        #endif
        log.notice("stopTunnel: surfaces told — status=1 since=none (T-EXT-1)")
    }

    // MARK: - Folding this session into the protected-time total (T-UX-7)
    //
    // ⚠️ THIS PROCESS IS THE ONLY WITNESS, for the same reason publishStoppedToSurfaces above it is.
    // The app observes NEVPNStatus only while it is running; a tunnel raised on demand and dropped
    // hours later with the app suspended is invisible to it — and that is the ORDINARY case for a
    // VPN nobody has to think about, so an app-side total would be wrong in the case that matters
    // most. This function brackets exactly one session and adds its length to a running total.
    //
    // WHAT IT WRITES IS TWO INTEGERS AND CANNOT BECOME MORE. `AppGroup.addProtectedSession` takes a
    // duration and nothing else — no start, no end, no node, no reason — so this cannot turn into a
    // session log even by accident, which is the property the whole feature rests on. Read that
    // function's header for the argument; it is the decision record, not this call site.
    //
    // THE APPEX'S AUDITED LINK SET IS UNTOUCHED: `AppGroup` is already in MorkeShared and already
    // written from this very function's neighbour, so the marginal cost is one small `Data` encode
    // and one atomic write of a ~30-byte file — no framework, no timer, no subscription.
    //
    // ⚠️ THAT DISTINCTION IS WHY BYTES UP/DOWN ARE NOT HERE — measured 2026-09-09, T-UX-7, so nobody
    // re-derives it. They ARE reachable: `LibboxStatusMessage` in our own shipped headers carries
    // `trafficAvailable` / `uplink` / `downlink` / `uplinkTotal` / `downlinkTotal`
    // (Libbox.objc.h:1051-1055), and those accessors plus `experimental/clashapi/trafficontrol`
    // survive T-ARCH-31's trim at the SYMBOL level in the shipped ios-arm64 slice (`nm -gU` on
    // Frameworks/Libbox.xcframework → `proxylibbox_StatusMessage_UplinkTotal_Get` and its
    // neighbours) — the trim removed registry entries and build tags, and `with_clash_api` was
    // deliberately retained. What makes them a different KIND of work is how they are delivered:
    // only through a `LibboxCommandClient` opened against the command server with a `statusInterval`
    // — a live subscription running for the whole session, not a value that can be read once at
    // stop — and the totals reset with the engine, so they would have to be folded periodically.
    // The app process cannot shortcut it either: Libbox.xcframework is linked by the two MorkeTunnel
    // targets ONLY, never by the app. So surfacing bytes means a subscription plus a timer plus
    // repeated App-Group writes inside the memory tier whose enforced metric is still unresolved
    // (T-CFG-16) — which is exactly what a one-shot fold at stop is not. Reachable, priced, and
    // deliberately not built.
    //
    // Best-effort and non-blocking, like everything else on this deadline: no throw, no wait, and a
    // start we never recorded simply counts nothing rather than guessing a length.
    private func recordProtectedSession() {
        guard let startedAtMonotonic else { return }
        // Monotonic, deliberately — see the property's own comment. `.components.seconds` truncates
        // toward zero, which is the direction that cannot over-claim.
        let elapsed = ContinuousClock.now - startedAtMonotonic
        let seconds = Int(elapsed.components.seconds)
        self.startedAtMonotonic = nil
        AppGroup.addProtectedSession(seconds: seconds)
        log.notice("stopTunnel: protected session recorded — seconds=\(seconds, privacy: .public) (T-UX-7)")
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log.notice("sleep: pausing tunnel")
        TunnelDiagnostics.record(.slept)
        singBox?.pause()
        completionHandler()
    }

    override func wake() {
        log.notice("wake: resuming tunnel")
        TunnelDiagnostics.record(.woke)
        singBox?.wake()
    }

    // MARK: - App → extension diagnostic message (T-INFRA-27)
    //
    // Deliberately trivial, and it must stay that way — more so now the feature is permanent
    // (T-INFRA-28) than when it was expected to be removed: this runs inside the Packet-Tunnel
    // memory budget, and a growing message handler spends it. It answers ONE request with THREE
    // facts about this process — whether an engine object exists, when the start was accepted, and
    // the config's size in bytes. Any other payload gets a nil reply, so this cannot grow into a
    // command channel by accident. Nothing about traffic, destinations or the config's content is
    // readable through it.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard String(data: messageData, encoding: .utf8) == TunnelDiagnostics.stateRequest else {
            completionHandler?(nil)
            return
        }
        let state = TunnelDiagnostics.State(
            running: singBox != nil,
            startedAt: startedAt,
            configBytes: configBytes
        )
        completionHandler?(try? JSONEncoder().encode(state))
    }
}

// MARK: - TunnelStartError

private enum TunnelStartError: LocalizedError {
    case notAuthorized
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "No matching activation key in Keychain — connect from the app to authenticate first."
        case .missingConfig:
            // Deliberately does not name a store: it is the Keychain on iOS and providerConfiguration on
            // macOS (T-CFG-41), and the user-facing remedy is the same either way.
            return "No sing-box config available — connect from the app to set it up first."
        }
    }
}
