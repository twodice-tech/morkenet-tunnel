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
import Security

// Defined at file scope — does not inherit any actor isolation (Docs/tca.md: state enums outside structs).
public enum SharedKeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

// TCA-free keychain reader compiled into both Morke and MorkeTunnel.
// The extension uses this to read activation_key without waking the main app.
//
// Two-namespace split — deliberate, do NOT "unify" the two reverse-DNS prefixes:
//   • tech.twodice.morke — bundle id · App Group ("group.tech.twodice.morke") · os_log subsystem.
//   • tech.morke         — Keychain service + access-group suffix ("tech.morke.shared").
// A rename that "fixes" one namespace but not the other silently breaks app↔extension Keychain
// sharing: SecItemCopyMatching → errSecItemNotFound → TunnelStartError.notAuthorized, no compile error.
public enum SharedKeychain {

    // MARK: - Shared keychain identity (single source of truth for both targets)

    // `nonisolated` throughout: the extension reads these off the main actor (loadActivationKey is
    // nonisolated), and the project defaults type-level declarations to @MainActor isolation. All are
    // immutable Sendable values, so opting out of actor isolation is safe and required here.

    // Keychain service shared by the app and the extension.
    public nonisolated static let service = "tech.morke"

    // Account under `service` that holds the activation key.
    public nonisolated static let activationKeyAccount = "activation_key"

    // Account under `service` that records that the user ACKNOWLEDGED the activation key on the
    // save-key screen (T-AUTH-26). Presence is the whole signal — the value is a placeholder. It sits
    // here, beside the key rather than in UserDefaults, because acceptance is given once and for good
    // and must share the key's lifetime: UserDefaults is wiped when the app is deleted while the
    // Keychain survives it, which would re-ask a user who had already accepted. App-only (the
    // extension neither shows UI nor cares), kept in the same Keychain identity for consistency.
    public nonisolated static let activationKeyAckAccount = "activation_key_ack"

    // Account under `service` that holds the App-Attest keyId (T-INFRA-11). App-only (the extension
    // does not make attested API calls), but kept in the same Keychain identity for consistency.
    // Not a secret — it is Apple's SHA256(publicKey) — but persisted here per "credentials in
    // Keychain only" and so it survives launches (regenerated on reinstall / loss — see resetKey).
    public nonisolated static let attestKeyIdAccount = "attest_key_id"

    // Account under `service` that holds the sing-box tunnel config JSON (T-CFG-41). The ONE account
    // here whose value is written by the app and read by the EXTENSION — the config carries a live
    // proxy credential (the per-account VLESS UUID) plus the REALITY parameters, which is why it moved
    // out of NETunnelProviderProtocol.providerConfiguration (unencrypted NE preferences, readable for as
    // long as the profile is installed) into this Keychain identity. iOS ONLY — see the trio below.
    // A CACHE, never the only copy: the bytes always come from POST /api/v1/auth/config and any loss
    // heals through an ordinary foreground re-fetch (Q34 — the go-live REALITY rotation has no grace
    // window, so nothing may depend on the stored copy surviving).
    public nonisolated static let tunnelConfigAccount = "tunnel_config"

    // Account under `service` that holds the device-session credential (T-AUTH-17 / B-FUT-2). A
    // SEPARATE secret from the App-Attest keyId: minted once by the backend on the FIRST login and
    // replayed in the login BODY (never a header on iOS) on every later login so the same device
    // session is reused instead of minting a new one. App-only (the extension never logs in), kept
    // in the same Keychain identity for consistency; dropped alongside the activation key on sign-out
    // / definitive 401.
    public nonisolated static let deviceCredentialAccount = "device_credential"

    // Accessibility class for EVERY item under this identity — one constant so no two write paths can
    // drift apart. `AfterFirstUnlockThisDeviceOnly` is what makes the items readable by the extension on
    // an on-demand raise after the first unlock, while staying non-exportable (no iCloud, no backup,
    // no migration to another device). The single-constant rule is load-bearing for T-CFG-41: the
    // config and the activation key MUST become unavailable together, never apart — a config on a laxer
    // class could be read at a moment the key could not, and T-CFG-45's gate (key ⟹ this config) would
    // then be comparing against a key the appex failed to read. It also means moving the config here
    // adds NO new pre-first-unlock failure: the key read already fails there, so the start already did.
    public nonisolated static let accessibility: String = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    // Suffix the access group always ends with (the "tech.morke" namespace, NOT the bundle id).
    private nonisolated static let accessGroupSuffix = "tech.morke.shared"

    // Hand-resolved fallback ($(AppIdentifierPrefix) = "VM3XX8889Q."). Used ONLY if the runtime
    // probe below fails (e.g. keychain locked before first unlock in the extension) — keeping the
    // value effectively in one place while guaranteeing the NE can always read the activation key.
    private nonisolated static let fallbackAccessGroup = "VM3XX8889Q.\(accessGroupSuffix)"

    // The shared access group, resolved at runtime so it tracks the real signing team instead of a
    // hand-resolved prefix. Single source of truth used by both SharedKeychain and KeychainClient.
    // Resolves once (thread-safe static let); a derivation miss falls back to the constant above so
    // it can NEVER break Keychain access.
    public nonisolated static let accessGroup: String = resolveAccessGroup() ?? fallbackAccessGroup

    // MARK: - Data-protection keychain

    // Opt every SecItem query into the data-protection keychain on macOS. Scoped to macOS so iOS stays
    // byte-identical: on iOS the data-protection keychain is the ONLY keychain (this flag is already the
    // default), whereas macOS defaults to the legacy file-based keychain. The sandboxed MorkeTunnel
    // sysext can only share the activation key with the app via `keychain-access-groups` on the
    // data-protection keychain — the file-based macOS keychain does not honour access groups the same
    // way, so the sysext's read returns errSecItemNotFound → "activation key absent from Keychain" and
    // the tunnel can't authenticate. It also makes kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly's
    // non-exportable / no-iCloud-or-backup guarantee hold on macOS, not just iOS (fable-5 audit #1).
    public nonisolated static func dataProtected(_ query: [String: Any]) -> [String: Any] {
        #if os(macOS)
        var q = query
        q[kSecUseDataProtectionKeychain as String] = true
        return q
        #else
        return query
        #endif
    }

    // MARK: - Runtime access-group derivation

    // Derives "<TeamPrefix>.tech.morke.shared" using only public SecItem* APIs (App-Store-safe):
    // add a throwaway generic-password item WITHOUT kSecAttrAccessGroup, so the OS files it under
    // the app's default keychain access group ("<TeamPrefix>.<first entitlement group>"); read that
    // back, keep the team prefix, recombine with our fixed suffix, delete the probe. Returns nil on
    // any failure so the caller falls back to the constant. No private entitlement-reading API is
    // used (SecTaskCopyValueForEntitlement lives in non-public SecTask.h on iOS), so no App Review risk.
    private nonisolated static func resolveAccessGroup() -> String? {
        let identity: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: "access-group-probe",
            kSecAttrService as String: "tech.morke.access-group-probe"
        ]

        // Clear any probe left over from a previous interrupted run.
        SecItemDelete(dataProtected(identity) as CFDictionary)

        var addAttributes = identity
        addAttributes[kSecReturnAttributes as String] = true
        addAttributes[kSecAttrAccessible as String]   = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

        var result: AnyObject?
        let status = SecItemAdd(dataProtected(addAttributes) as CFDictionary, &result)

        // Always remove the probe, whatever the outcome.
        SecItemDelete(dataProtected(identity) as CFDictionary)

        guard
            status == errSecSuccess,
            let attributes = result as? [String: Any],
            let defaultGroup = attributes[kSecAttrAccessGroup as String] as? String
        else { return nil }

        // Default group is "<TeamPrefix>.<group-name>" — keep only the team prefix, then recombine
        // with our suffix (robust even if the default group is the application-identifier group).
        let components = defaultGroup.split(separator: ".", maxSplits: 1)
        guard components.count == 2, let teamPrefix = components.first, !teamPrefix.isEmpty else {
            return nil
        }
        return "\(teamPrefix).\(accessGroupSuffix)"
    }

    // MARK: - Read

    // T-ARCH-24: THE generic-password read for this Keychain identity — the only SecItem read
    // implementation in the repo. Both callers route through it: loadActivationKey below (compiled
    // into the extension, which reads the key cross-target) and MorkeServices' GenericKeychainItem
    // .load (app-side, for the attest keyId / device credential). They used to be hand-mirrored
    // copies of the same query, and a divergence across that app↔NE wall produces NO compile error
    // — it surfaces only as SecItemCopyMatching → errSecItemNotFound → TunnelStartError
    // .notAuthorized at tunnel start, exactly the failure mode this file's header warns about.
    // Parameterised rather than moved: no app-side code enters MorkeShared, so the extension's link
    // set is unchanged.
    //
    // Returns nil when the item does not exist; throws SharedKeychainError.unexpectedStatus for
    // Security-framework failures.
    //
    // T-CFG-41: the byte-level read moved down into loadData below, so the sing-box config (Data, not a
    // UTF-8 string) does not introduce a SECOND SecItem read implementation — the exact drift this
    // header warns about. This stays the string front door: same query, plus the UTF-8 decode.
    public nonisolated static func loadString(
        service: String,
        account: String,
        accessGroup: String
    ) throws -> String? {
        guard let data = try loadData(service: service, account: account, accessGroup: accessGroup) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SharedKeychainError.unexpectedStatus(errSecInternalError)
        }
        return value
    }

    // T-ARCH-24 / T-CFG-41: THE generic-password read for this Keychain identity — every read in the
    // repo, string or Data, app-side or extension-side, bottoms out here.
    //
    // Returns nil when the item does not exist; throws SharedKeychainError.unexpectedStatus for
    // Security-framework failures. The nil/throw split is load-bearing for both callers: "absent" is a
    // recoverable state (re-fetch, re-login), a non-`errSecItemNotFound` status is not, and collapsing
    // the two — the `try?` this deliberately avoids — is what makes a locked keychain look like a
    // signed-out user.
    public nonisolated static func loadData(
        service: String,
        account: String,
        accessGroup: String
    ) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(dataProtected(query) as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SharedKeychainError.unexpectedStatus(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SharedKeychainError.unexpectedStatus(status)
        }
    }

    // Returns the stored activation_key, or nil if the item does not exist.
    // Throws SharedKeychainError.unexpectedStatus for Security framework failures.
    public nonisolated static func loadActivationKey() throws -> String? {
        try loadString(service: service, account: activationKeyAccount, accessGroup: accessGroup)
    }

    // MARK: - Sing-box tunnel config (T-CFG-41, iOS only)

    // iOS ONLY — AND NOT BY PREFERENCE. On macOS the tunnel is a SYSTEM EXTENSION that runs sandboxed
    // and AS ROOT, in the system context rather than the user session: SecItem there returns
    // errSecNotAvailable, which is precisely why T-MAC-10 failed and why the macOS start-time gate is a
    // providerConfiguration flag instead (T-MAC-14). On macOS the config therefore STAYS in
    // providerConfiguration. Do not "finish" this move on the Mac — it would stop the tunnel starting
    // at all. The #if is what keeps that from being a silent, runtime-only discovery.
    #if os(iOS)

    // Reads the stored sing-box config. nil when nothing is stored (a fresh install, an install upgraded
    // from a build that kept the bytes in providerConfiguration, or a post-sign-out state) — the caller
    // must FAIL THE START CLOSED on nil and let the next in-app connect re-fetch and re-store. Throws on
    // a genuine Security-framework failure, kept distinct from nil for the same reason loadData does.
    public nonisolated static func loadTunnelConfig() throws -> Data? {
        try loadData(service: service, account: tunnelConfigAccount, accessGroup: accessGroup)
    }

    // Stores (or replaces) the sing-box config. Called by the app on every connect, immediately before
    // the profile is saved, so the stored bytes are always the ones the profile is about to run.
    public nonisolated static func saveTunnelConfig(_ config: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     tunnelConfigAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String:  accessibility,
            kSecValueData as String:       config
        ]
        var status = SecItemAdd(dataProtected(attributes) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Add-vs-update: the item exists from a previous connect, so switch to an update. The
            // accessibility class is set on add only — an update never relaxes it.
            let query: [String: Any] = [
                kSecClass as String:           kSecClassGenericPassword,
                kSecAttrService as String:     service,
                kSecAttrAccount as String:     tunnelConfigAccount,
                kSecAttrAccessGroup as String: accessGroup
            ]
            status = SecItemUpdate(
                dataProtected(query) as CFDictionary,
                [kSecValueData as String: config] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw SharedKeychainError.unexpectedStatus(status)
        }
    }

    // Drops the stored config. Idempotent (errSecItemNotFound is success), so the sign-out / reset scrub
    // can call it unconditionally. Run wherever the profile is removed or the user signs out — a config
    // that outlives sign-out is a live proxy credential belonging to an account that is no longer here.
    public nonisolated static func deleteTunnelConfig() throws {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     tunnelConfigAccount,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(dataProtected(query) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedKeychainError.unexpectedStatus(status)
        }
    }
    #endif
}
