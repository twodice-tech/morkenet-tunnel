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
#if os(iOS)
// T-CFG-45: SHA-256 for the iOS start-time key fingerprint below. A SYSTEM framework, so MorkeShared
// stays package-dependency-free (its header requirement) and the NE memory budget is unaffected.
// Scoped to iOS so the macOS build links exactly what it linked before.
import CryptoKit
#endif

public nonisolated enum AppGroup {
    public static let appGroupID = "group.tech.twodice.morke"
    // providerConfiguration key written by the app and read by the NE — shared across both targets.
    public static let singBoxConfigKey = "singBoxConfigJSON"

    // macOS-only auth guard in providerConfiguration — and the ONLY app→extension channel this platform
    // has (T-MAC-14, corrected on device 2026-08-04). The macOS system extension runs SANDBOXED AND AS
    // ROOT, in the system context rather than the user session, so BOTH shared stores the iOS appex
    // relies on are unreachable from it:
    //   • the user keychain — SharedKeychain returns errSecNotAvailable there; and
    //   • the App-Group container — containerURL(forSecurityApplicationGroupIdentifier:) resolves PER
    //     USER, so the app (console user) gets ~/Library/Group Containers/group.tech.twodice.morke/
    //     while the extension gets /var/root/Library/Group Containers/…. Neither process can see what
    //     the other writes. Do NOT use that container as an app↔sysext channel on macOS.
    // What is left is providerConfiguration, which the OS itself carries into the extension. So the app
    // passes this non-secret "user is authenticated" flag there for startTunnel to guard on, instead of
    // the extension reading the activation key from the shared Keychain (how the iOS appex does it).
    // Cleared on sign-out by removeProfile(), which drops the whole profile — and, when that throws, by
    // the in-place fallback clear in VPNCore.removeProfile() that keeps the gate failing closed.
    public static let macOSAuthenticatedKey = "macOSAuthenticated"

    // Resolves the real App-Group container. nil when it can't be resolved (off-device / no
    // entitlement) — a nil container makes the gate helpers below read as NOT authorised
    // (FAIL-CLOSED). Private; the public helpers take an INJECTABLE `container` seam (mirroring
    // TunnelWorkspace.wipe(container:)) and fall back to this when none is passed.
    //
    // T-CFG-53 moved this OUT of the `#if os(iOS)` block below, byte-unchanged, so the re-arm intent
    // can use it on both platforms. The iOS-only restriction was never about resolving a container —
    // it was about using one as an app↔EXTENSION channel, which on macOS is impossible (containerURL
    // resolves PER USER and the sysext runs as root; see macOSAuthenticatedKey above). Nothing added
    // below crosses that boundary: the re-arm intent is written and read by the APP process only.
    // T-EXT-0 widened this from `private` to module-internal, byte-unchanged otherwise, so the
    // VPN-surface store in VPNSurfaceState.swift resolves the container through the SAME function
    // rather than growing a second copy of it — one derivation, and one place where fail-closed on
    // an unresolvable container is decided. Still not public: outside MorkeShared the container is
    // reached only through the helpers that already carry that discipline.
    static func defaultContainer() -> URL? {
        containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    // TEST SEAM, and it is a `@TaskLocal` for a specific reason (T-EXT-1, 2026-09-08).
    //
    // The App-Group document is process-global, and since T-EXT-1 gave HomeFeature a third publish
    // site every HomeFeature suite writes it as a side effect of reducing. Two consequences, both
    // measured rather than feared: a suite that ASSERTS on the document fails when another suite
    // publishes concurrently (swift-testing parallelises within a target — this failed exactly that
    // way before the seam existed), and a plain test run rewrites the real widget's state on the
    // simulator or device it ran on.
    //
    // This is the same order-dependence T-QA-27 removed from UserDefaults, and it takes the same
    // answer: per-case isolation, not a shared store. A `@TaskLocal` rather than a mutable static
    // because parallel cases each need their own value — a `static var` would be the very defect
    // being fixed — and because it propagates into the child tasks TCA effects run on, which is
    // where the publish actually happens.
    //
    // `nil` in production, always: nothing in the app or the extension sets it, so `defaultContainer`
    // resolves exactly as it did before. It costs the appex one optional read per container lookup.
    // `public` because MorkeTests is an Xcode target outside this package, so `package` would not
    // reach it. It is a seam, not API: the same shape as the `container:` parameter every helper
    // below already exposes publicly for the same reason.
    @TaskLocal public static var containerOverride: URL?

    // MARK: - On-demand re-arm intent (T-CFG-53)
    //
    // WHAT IT RECORDS, and nothing else: "on-demand SHOULD be armed — the user's settings ask for it
    // — but the installed profile had no config the extension could start, so we took it away." It is
    // not a copy of the preference (AppSettings holds that) and not a record of the tunnel's state.
    //
    // WHY IT HAS TO EXIST. T-CFG-52 made an armed-but-unstartable profile disarm itself, which is what
    // ends the unbounded restart loop — but that disarm is SILENT AND PERMANENT until the user next
    // taps Connect. With the kill switch on, that is the whole protection gone, with nothing on screen
    // saying so, for a reason the user did not cause: an app update whose bundle replacement left the
    // config store stale. This turns "off" into "off BECAUSE it could not start", which is the only
    // thing separating a state the app can repair by itself from one that is indistinguishable from
    // the user having switched the feature off — and those two must never be conflated, because
    // re-arming the second one would override a deliberate choice.
    //
    // LIFETIME is exactly right by construction. The App-Group container survives an app UPDATE — the
    // case this exists for — and is destroyed by an UNINSTALL, where a fresh install has no profile
    // and nothing to repair. Presence of the file IS the value: nothing to decode, no partial state,
    // no migration. Deliberately NOT the Keychain (it is not a secret) and NOT AppSettings (it is not
    // a user preference and must never surface as one, nor be exported/restored with them).

    private static let onDemandRearmPendingName = "on-demand-rearm-pending"

    // Best-effort on purpose (`try?`, no throw): a write that fails simply loses the intent and the
    // behaviour degrades to what it was before this existed — a disarm that waits for the user. The
    // opposite bias would be worse, and there is no caller that could act on the error.
    public static func setOnDemandRearmPending(_ pending: Bool, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        let url = container.appendingPathComponent(onDemandRearmPendingName)
        if pending {
            try? Data().write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // An unresolvable container reads FALSE — no intent, no automatic connect. Same fail-closed bias
    // as the gate helpers below: the failure mode of a wrong `true` here is raising a tunnel nobody
    // asked for, which is strictly worse than not repairing one.
    public static func isOnDemandRearmPending(container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent(onDemandRearmPendingName).path
        )
    }

    // MARK: - Surface connect request (T-EXT-0)
    //
    // WHAT IT RECORDS: "the user asked for a connect from OUTSIDE the app, and the intent could not
    // do it here." Only the two refusals whose documented repair is an in-app connect set it — no
    // profile installed, and no stored config (T-CFG-41). Not `.notSignedIn` (they land on the login
    // screen, which is its own flow) and not `.busy` (nothing to repair).
    //
    // WHY IT EXISTS. Opening the app on Home is a truthful answer but a thin one: the user pressed a
    // control and the thing they pressed it for did not happen, with no route to the reason. It is
    // sharpest for an unsubscribed account, where the honest destination is the paywall — and the
    // intent CANNOT work that out for itself: it runs in a background app process where AuthSession
    // is empty by construction, so entitlement is unknowable there without a network round trip
    // inside a toggle. The app, once open, already knows: replaying the connect puts the user through
    // the SAME gates a Connect tap does, and those gates present the paywall. So this carries the
    // intent across the process boundary rather than duplicating a judgement in the wrong place.
    //
    // AT MOST ONCE, and consumed rather than read: the user asked once. Cleared by the consume, by a
    // failed silent re-login (no session, nothing to replay), and by TunnelWorkspace.wipe() on
    // sign-out — so a request can never outlive the account that made it.
    //
    // Same file-presence shape and the same best-effort bias as the re-arm intent above: presence IS
    // the value, an unresolvable container reads false, and a lost write costs one replay rather than
    // producing one nobody asked for.

    private static let pendingSurfaceConnectName = "surface-connect-pending"

    public static func setPendingSurfaceConnect(_ pending: Bool, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        let url = container.appendingPathComponent(pendingSurfaceConnectName)
        if pending {
            try? Data().write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func isPendingSurfaceConnect(container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent(pendingSurfaceConnectName).path
        )
    }


    // MARK: - Protected-time totals (T-UX-7)
    //
    // TWO INTEGERS, and the fact that there are only two is the whole privacy argument. This is a
    // FOLD, not a log: `sessions` counts how many tunnels this device has run to completion and
    // `seconds` sums how long they lasted. Neither has an inverse — no reading of the pair recovers
    // when any session started, when it ended, how long any ONE of them was, or where anyone was
    // while it ran. A stored ROW per session would recover all of that, which is why
    // ConnectionMetricsClient refused a per-session buffer and why this is not that refusal
    // reversed. The document has a FIXED SIZE that does not grow with use; if it ever needs an
    // array, the thing being added is a log and the answer is no.
    //
    // WHY THE EXTENSION OWNS IT, and it is the only process that can. The app observes NEVPNStatus
    // only while it is running: a tunnel raised on demand and dropped hours later, with the app
    // suspended the whole time — which is the ordinary case for a VPN nobody has to think about —
    // is invisible to it. This process brackets exactly one session, start to stop, so it is the
    // one witness that can measure the session at all. The app never writes `add`; the extension
    // never writes `clear`. One writer per operation, so a read-modify-write cannot lose an update
    // — the exception is a reset racing a stop, which costs one session and is stated at `clear`.
    //
    // WHAT THE NUMBER MEANS, exactly, so nothing over-claims: the EXTENSION'S OWN UPTIME, from the
    // moment iOS handed it a start to the moment it was stopped. It therefore includes the second
    // or two of setup before traffic flows, and it counts NOTHING for a session ended by a crash,
    // a jetsam kill or a reboot, where `stopTunnel` never runs. Both directions are small and the
    // second is the larger; the total is a close lower bound, never an inflated one.
    //
    // ⚠️ `seconds` MUST come from a MONOTONIC clock at the call site, never from two `Date()`
    // readings. A wall-clock correction mid-session would otherwise fold a jump straight into a
    // total the user can only fix by resetting it. See PacketTunnelProvider.stopTunnel.
    //
    // NOT A SECRET, so the App-Group rule at the top of VPNSurfaceState.swift is satisfied by
    // construction: two counters carry no destination, no address and no credential. Nothing reads
    // this but the app's own Settings screen — the widget and the Control Center control do not,
    // and must not start: what they render is the CURRENT connection, not a history of them.

    public struct ProtectedTimeTotals: Codable, Sendable, Equatable {
        // Sessions this device ran to a delivered stop. See the header for what it cannot count.
        public var sessions: Int
        // Their summed duration in whole seconds. Whole seconds because nothing on screen is finer
        // than a minute, and an Int cannot carry a fraction that hints at one session's exact length.
        public var seconds: Int

        public init(sessions: Int = 0, seconds: Int = 0) {
            self.sessions = sessions
            self.seconds = seconds
        }
    }

    private static let protectedTimeTotalsName = "protected-time-totals.json"

    // THE EXTENSION'S WRITE, and the only one. Best-effort throughout (`try?`, never throws): this
    // is called from stopTunnel, which runs on a deadline and may not be blocked or failed by a
    // statistic. A lost write costs one session out of a running total.
    //
    // A non-positive duration is DROPPED rather than clamped to zero and counted: it means the
    // measurement itself is unusable (no recorded start), and counting a session whose length we do
    // not know would inflate `sessions` against a `seconds` that never moved.
    public static func addProtectedSession(seconds: Int, container: URL? = nil) {
        guard seconds > 0 else { return }
        guard let container = container ?? defaultContainer() else { return }
        var totals = readProtectedTimeTotals(container: container)
        totals.sessions += 1
        totals.seconds += seconds
        guard let data = try? JSONEncoder().encode(totals) else { return }
        try? data.write(to: protectedTimeTotalsURL(container), options: .atomic)
    }

    // Read by the app. Every failure — unresolvable container, absent file, undecodable file —
    // answers ZEROS rather than nil, because there is exactly one honest thing to say when we have
    // no measurement and it is "nothing counted yet". A caller cannot act on the difference.
    public static func readProtectedTimeTotals(container: URL? = nil) -> ProtectedTimeTotals {
        guard let container = container ?? defaultContainer() else { return ProtectedTimeTotals() }
        guard let data = try? Data(contentsOf: protectedTimeTotalsURL(container)) else {
            return ProtectedTimeTotals()
        }
        return (try? JSONDecoder().decode(ProtectedTimeTotals.self, from: data)) ?? ProtectedTimeTotals()
    }

    // The app's reset, and the one write the extension never makes. A stop landing in the same
    // instant can leave that session counted on the far side of the reset; it costs one session and
    // the user can press reset again, which is why it is not worth a lock across two processes.
    // Also called from the sign-out / account-deletion scrub — see SettingsFeature.runLocalScrub.
    public static func clearProtectedTimeTotals(container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? FileManager.default.removeItem(at: protectedTimeTotalsURL(container))
    }

    private static func protectedTimeTotalsURL(_ container: URL) -> URL {
        container.appendingPathComponent(protectedTimeTotalsName)
    }

    #if os(iOS)
    // MARK: - iOS sing-box config location (T-CFG-41)
    //
    // On iOS the config bytes live in the SHARED KEYCHAIN (SharedKeychain.loadTunnelConfig), not in
    // providerConfiguration — they carry a live proxy credential (the per-account VLESS UUID) plus the
    // REALITY parameters, and NE preferences are unencrypted for as long as the profile is installed.
    // What stays in providerConfiguration is this NON-SECRET marker: it says a config is expected, and
    // nothing about which one. macOS keeps the bytes themselves there, because its root-run sysext can
    // read neither the user keychain nor the app's App-Group container (T-MAC-14).
    //
    // WHY A MARKER AT ALL, when the extension could simply read the Keychain and refuse on nil. It
    // separates two failures that otherwise look identical at the gate and need different responses:
    // a profile this build never saved (an install upgraded from a build that stored the bytes in
    // providerConfiguration — see below) versus a stored config that is missing or unreadable. Both
    // refuse the start; only the first is expected, and one log line apart they are indistinguishable.
    //
    // UPGRADE PATH — RE-FETCH, NOT MIGRATE (decision). An install upgraded across this change has bytes
    // in providerConfiguration and nothing in the Keychain; the iOS read path ignores those bytes
    // entirely, so an on-demand raise refuses until the user connects once from the app. That connect
    // re-fetches (or reuses the cached config), stores it here, and REPLACES providerConfiguration with
    // this marker alone — which is also what finally drops the stale credential out of NE preferences.
    // Migrating instead would save one round trip and cost a launch-time NE preferences read+write plus
    // a code path that is dead the moment every install has connected once. Re-fetch is the same path
    // that must already heal a missing or stale store after the go-live REALITY rotation (Q34 /
    // B-SAFE-3, no grace window), so it is the one path worth having and worth exercising.
    public static let iOSConfigInKeychainKey = "configInKeychain"

    // The extension's marker predicate, in one place so the app's write and the appex's read cannot
    // drift. FAIL-CLOSED by construction: a nil dictionary, an absent key, `false`, and any non-Bool
    // value all read as "no config expected". Pure and nonisolated so the off-device suite can assert
    // the whole table (same seam as VPNCore.deauthorizedProviderConfiguration — every NE call around it
    // needs a provisioned device).
    public static func expectsKeychainConfig(_ providerConfiguration: [String: Any]?) -> Bool {
        providerConfiguration?[iOSConfigInKeychainKey] as? Bool == true
    }

    // MARK: - iOS activation-key fingerprint (T-CFG-45)
    //
    // Binds the iOS start-time gate to the CONFIG IT IS ABOUT TO RUN. The appex used to run two guards
    // that never talked to each other: it read the activation key from the shared Keychain, checked it
    // was non-empty and discarded it, then separately read providerConfiguration[singBoxConfigKey] — so
    // ANY non-empty key unlocked WHATEVER config happened to be sitting in the profile. Reachable
    // because sign-out's removeProfile() is best-effort (a throw leaves the profile + on-demand rules
    // armed) and, more importantly, because T-AUTH-19 deliberately RETAINS the key and the profile on an
    // involuntary session expiry: paste a DIFFERENT account's key on the Welcome screen and the Keychain
    // holds account B's key while providerConfiguration still holds account A's VLESS config — an
    // on-demand trigger then raises the tunnel on A's credentials.
    //
    // WHY A FINGERPRINT AND NOT A PRESENCE MARKER. (T-MAC-10 once kept such a marker here for macOS; it
    // was deleted by T-MAC-14, which found the two processes never share a container on that platform.
    // The reasoning below is why iOS would not have copied it even if it had worked.) A presence marker
    // is the obvious symmetric fix and it is INSUFFICIENT: one written on connect and cleared on sign-out is still
    // PRESENT in the expiry path above, because no sign-out ever ran. The gate must compare IDENTITY,
    // not existence — so this file carries the digest of the key that was live when the config was saved,
    // and startTunnel re-hashes the key it just read and requires equality.
    //
    // WHY AN UNSALTED DIGEST IS ACCEPTABLE. The activation key is 16 Crockford base32 characters = 80
    // bits of uniform random entropy, so the digest is neither brute-forceable nor a dictionary target;
    // a salt would add a second stored value with no threat it defends against (and would fail the
    // smallest-change test). ONLY the digest is written — the key itself never leaves the Keychain
    // (CLAUDE.md). File protection is the iOS default (complete-until-first-user-authentication), which
    // matches the key item's kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: pre-first-unlock the
    // Keychain read already fails, so the two gates become unavailable together, never apart.
    //
    // Second, independent property, inherited from T-MAC-10: TunnelWorkspace.wipe() clears this file on
    // sign-out INDEPENDENTLY of removeProfile(), so a thrown profile removal still fails the gate closed.

    // Fingerprint file name inside the App-Group container.
    private static let iOSKeyFingerprintName = "ios-key-fingerprint"

    // SHA-256 over the key's UTF-8 bytes. The ONLY derivation — write and compare must never diverge.
    private static func fingerprint(of activationKey: String) -> Data {
        Data(SHA256.hash(data: Data(activationKey.utf8)))
    }

    // Writes the digest of the key that authorises the config being saved. Best-effort (try?): a write
    // failure leaves the PREVIOUS digest in place, which is the fail-closed outcome — it still matches
    // for the same account and still refuses for a different one. Called from VPNCore.connect, before
    // saveToPreferences/startVPNTunnel, so it is present for the start-time guard.
    public static func writeIOSKeyFingerprint(for activationKey: String, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? fingerprint(of: activationKey).write(to: container.appendingPathComponent(iOSKeyFingerprintName))
    }

    // True iff the stored digest exists AND equals the digest of `activationKey`. An unresolvable
    // container, an unreadable/absent file, and a truncated or otherwise non-matching digest ALL read
    // false — FAIL-CLOSED. Called from the iOS startTunnel guard.
    public static func iOSKeyFingerprintMatches(_ activationKey: String, container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        guard let stored = try? Data(contentsOf: container.appendingPathComponent(iOSKeyFingerprintName)) else {
            return false
        }
        return stored == fingerprint(of: activationKey)
    }

    // Removes the fingerprint. Best-effort (try?): a missing file is a no-op, so sign-out stays
    // BEST-EFFORT and this never throws or blocks the wipe path. Called from TunnelWorkspace.wipe(),
    // which sign-out runs unconditionally AFTER the best-effort removeProfile() — so the gate is cleared
    // regardless of removeProfile()'s outcome.
    public static func clearIOSKeyFingerprint(container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(iOSKeyFingerprintName))
    }
    #endif
}
