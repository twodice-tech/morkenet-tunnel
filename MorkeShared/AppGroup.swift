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
    private static func defaultContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

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
