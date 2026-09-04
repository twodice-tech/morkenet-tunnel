# Morke tunnel — Corresponding Source

This repository is the **Corresponding Source** (GNU GPL v3 § 1) for
`MorkeTunnel.appex`, the Network Extension inside the Morke VPN applications for
iOS and macOS.

It exists because the extension statically links
[sing-box](https://github.com/SagerNet/sing-box), which is licensed
GPL-3.0-or-later. Shipping that through the App Store is **conveying**, and GPLv3
§ 5(c) requires the entire extension, as a whole, to be licensed under the same
terms to anyone who comes into possession of a copy. § 6 then requires us to
offer the source. This is that offer, discharged by publication.

**Pinned engine: sing-box `v1.13.13`.**

---

## What is here

| Path | What it is |
|---|---|
| `MorkeTunnel/PacketTunnelProvider.swift` | the `NEPacketTunnelProvider` subclass — start/stop/sleep/wake, on-demand handling, configuration read |
| `MorkeTunnel/SingBoxTunnel.swift` | the libbox engine wrapper: `LibboxCommandServer` setup → start → stop |
| `MorkeTunnel/ExtensionPlatformInterface.m/.h` | the Objective-C bridge implementing `LibboxPlatformInterface` and `LibboxCommandServerHandler` — TUN file-descriptor handover, interface enumeration, default-route monitoring, socket binding |
| `MorkeTunnel/MorkeTunnelNetHelpers.c/.h` | pure-C address and interface-classification helpers, split out so they can be unit-tested off-device |
| `MorkeTunnel/MorkeTunnel-Bridging-Header.h` | Swift ↔ Objective-C bridging header |
| `MorkeTunnel/Info.plist`, `*.entitlements`, `PrivacyInfo.xcprivacy` | the bundle configuration and build inputs needed to generate and install the extension |
| `MorkeShared/` | the app↔extension surface module the extension links: App Group keys, shared-Keychain accessors, the opaque configuration wrapper, the `os_log` subsystem, the diagnostics wire types |
| `LICENSE` | GNU GPL v3, with an explicit scope notice at the top |
| `BUILD.md` | how to build libbox from the pinned tag, and the extension's complete build configuration |
| `MANIFEST.md` | the rule that decides what belongs in this repository, and the resolved file list with digests |

## What is *not* here, and why

This is the tunnel extension, not the product. Deliberately absent, because none
of it is compiled into the extension and none of it is therefore covered by
§ 5(c):

- the iOS and macOS client applications, their UI and their state management;
- authentication, the paywall and StoreKit purchase handling, App Attest,
  TLS public-key pinning, device-session management, the entitlement gate;
- the server node list, the routing logic and every piece of backend knowledge;
- the Morke backend service itself;
- the Morke name, logo, icons and artwork, which are trademarks and are not
  licensed by `LICENSE` at all.

**The copyleft boundary is set by linking, not by repository layout.** This
repository exists to make § 6 satisfiable and § 5(c) legible. Splitting the
source did not create the boundary and does not move it.

### One module is dual-licensed

`MorkeShared/` is our own code and is linked by **both** binaries — this GPL
extension and the closed-source client. As the copyright holder we license it
twice: to you under the GPL, unconditionally, and to ourselves under our own
terms for the closed half. The first grant is not narrowed by the second. Every
file in `MorkeShared/` says so in its own header, and `LICENSE` says so again.

## Reading the comments

The comments here refer to things you cannot see: task identifiers like
`T-CFG-41` or `B-SAFE-3`, and documents like `singbox-integration.md` or
`smoke-test.md` that live in the closed Morke tree. Those references dangle, and
that is deliberate.

They are left intact because GPLv3 § 1 asks for *"the preferred form of the work
for making modifications"*, and in this code the reasoning **is** the value — why
`ENABLE_DEBUG_DYLIB` must be `NO`, why nothing touches libbox during class
initialisation, why the configuration lives in the Keychain on iOS and in
`providerConfiguration` on macOS, what the IPv6 leak block is defending against.
Editing that out to tidy the presentation would hand you a worse artefact than
the one we build from, and would make the published source diverge from the
shipped source. Treat an unresolvable identifier as a bookmark for a decision
that was made and recorded, not as a missing file.

## Component licences

The engine this extension links is not one project. The significant set, each
read at the pinned tag or at the linked module's own `LICENSE`:

| Component | Licence |
|---|---|
| `sagernet/sing-box`, `sing`, `sing-tun`, `sing-vmess`, `sing-quic`, `sing-mux`, `sing-shadowsocks`, `cronet-go` | GPL-3.0-or-later, plus a naming clause |
| `anytls/sing-anytls` | GPL-3.0-or-later |
| `sagernet/gvisor` | Apache-2.0 |
| `sagernet/quic-go`, `sagernet/wireguard-go`, `sagernet/smux` | MIT |
| `metacubex/utls`, `sagernet/tailscale`, `sagernet/gomobile` | BSD-3-Clause |

The sing-box licence appends a term we reproduce because § 4 requires notices to
be kept intact: *"no derivative work may use the name or imply association with
this application without prior consent."* It is a § 7(e)-style declining of
trademark rights and it restricts none of the freedoms the GPL grants.

The full texts of all of these are also reproduced inside the shipped
application, under **Settings → Legal → Open-source licences**, so that a
recipient who never visits this repository still receives them.

## Provenance, and what it does not prove

Each App Store submission tags this repository with the exact
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` of the build submitted, so the
§ 6(d) directions next to the object code resolve to the source that produced it.
`BUILD.md` records the sing-box pin and the complete build configuration.

**That is provenance. It is not proof of build equivalence, and no such proof is
offered here.** Building this source will not reproduce the shipped binary
bit-for-bit, and we do not claim it will. Two reasons, both outside our control:
Apple re-signs and encrypts the binary it delivers, and Swift and Xcode builds
are not bit-reproducible in the first place. Anyone telling you a published iOS
source tree proves what is in a downloaded `.ipa` is overstating it.

What *can* be checked independently, and is worth more than a promise:

1. **The libbox artefact.** Build `Libbox.xcframework` from tag `v1.13.13` by the
   recipe in `BUILD.md` and compare its SHA-256 with ours. That covers the half
   the GPL claim actually rests on — the engine — without depending on anything
   we assert.
2. **The absence of a network client in the extension.** The shipped appex
   contains no `URLSession` and no API base URL; it makes no control-plane call
   at all. That is checkable on a decrypted binary with no source whatsoever, and
   it is also recorded in `MorkeTunnel/PrivacyInfo.xcprivacy`.

## A note on the Apple Team ID

`MorkeShared/SharedKeychain.swift` contains the literal Team ID `VM3XX8889Q` as a
documented fallback Keychain access-group prefix, used only when the runtime
value cannot be resolved. It is published knowingly. It is not a secret: it is
recoverable from any signed Apple binary and from the provisioning profile, and
it authorises nothing on its own. If you rebuild this extension under your own
signing identity, that constant and the bundle identifiers in `BUILD.md` are what
you change.

## Contributing — pull requests are not the route here

**This repository is a publication target, not a development repository.** It is
regenerated by export from the closed Morke tree at every release, so anything
merged here would be silently overwritten by the next export. That is why pull
requests are closed: not to keep you out, but because merging one would quietly
lose your work.

**Open an issue instead.** A patch, a diff or a plain description in an issue is
welcome and is the form we can actually act on — we apply it upstream, and it
reaches you in the next release's export with your authorship recorded there.

One thing to know before you write a patch, because it cannot be repaired
afterwards:

- **`MorkeTunnel/` — ordinary GPL.** These files exist only inside the GPL
  extension. A change here is simply GPL code in a GPL work.
- **`MorkeShared/` — needs a copyright assignment or an explicit dual-licence
  grant.** This module is dual-licensed *only because a single party holds all of
  its copyright*. Someone else's GPL-licensed code landing in it could no longer
  ship inside the closed client, and the dual position `LICENSE` describes would
  quietly become false. Better said before you write it than after.

Your GPL rights do not depend on any of this. § 6 gives you the source and § 2
lets you fork and modify it however you like; the paragraphs above are about what
we can take *back* upstream, not about what you may do.

Support questions about the Morke application belong with the application, not
with this repository.
