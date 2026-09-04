# Building the Morke tunnel extension

This file is part of the Corresponding Source. GPLv3 § 1 defines it as *"all the
source code needed to generate, install, and … run the object code and to modify
the work, **including scripts to control those activities**"* — so the build
recipe is owed, not merely helpful. Everything needed to go from this repository
plus a sing-box checkout to a loadable `MorkeTunnel.appex` is written down here.

Read [README.md](README.md) first for what this repository is and is not.

---

## 1. The pin

**sing-box `v1.13.13`** — tag `v1.13.13` in
[`SagerNet/sing-box`](https://github.com/SagerNet/sing-box/tree/v1.13.13).

This is an exact tag, not a range. The pin matters twice over:

- **API.** Every sing-box release may change `LibboxPlatformInterface` method
  signatures. `ExtensionPlatformInterface.m` implements that protocol against
  `v1.13.13`'s generated `Libbox.objc.h`; a different tag may not compile, or
  may compile and mis-bridge.
- **Config schema.** The tunnel passes its configuration JSON through to libbox
  **verbatim** — it never generates or rewrites sing-box JSON. The configuration
  is a sing-box **1.13.x**-schema document (typed DNS servers, `sniff` /
  `hijack-dns` as `route` actions). A major/minor bump on either side needs a
  coordinated bump on the other.

---

## 2. Build `Libbox.xcframework` from source

No prebuilt releases exist; the framework is built from the pinned tag.

**Prerequisites**

- Go ≥ 1.22
- Xcode with the full command-line tools — `xcode-select -p` must point at
  `Xcode.app`, not at the CommandLineTools stub.

> **sing-box uses its own gomobile fork** (`github.com/sagernet/gomobile`),
> installed by `make lib_install`. Upstream `golang.org/x/mobile/cmd/gomobile`
> is **incompatible**. The Makefile target is **`lib_apple`** — there is no
> `lib_ios` target.

```sh
git clone --branch v1.13.13 https://github.com/SagerNet/sing-box.git
cd sing-box

# 1. Install SagerNet's gomobile/gobind fork into GOPATH/bin
make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"

# 2. Build the Apple xcframework (iOS device + simulator, macOS, tvOS)
#    Runs: go run ./cmd/internal/build_libbox -target apple
#    Takes several minutes; downloads many Go modules on first run.
make lib_apple

# 3. Place the output where the Xcode project expects it
find . -maxdepth 2 -name "Libbox.xcframework"
mv Libbox.xcframework <morke-tree>/Frameworks/Libbox.xcframework
```

`gomobile` itself is BSD-3-Clause. Its licence governs the **tool**, not the
sing-box code it wraps; the output is GPL-3.0-or-later like its input.

**The product is a static library.**
`Libbox.xcframework/ios-arm64/Libbox.framework/Libbox` is an `ar` archive —
`file(1)` says so. There is no dynamic-linking ambiguity here, which is why
§ 5(c) reaches the whole extension.

### Recording the artefact digest

```sh
find Libbox.xcframework -type f -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256
```

See [README.md § Provenance](README.md#provenance-and-what-it-does-not-prove)
for exactly what publishing that digest does and does not establish. It is not a
claim about the App Store binary.

---

## 3. Build settings for the `MorkeTunnel` target

The extension is an iOS app-extension target (`com.apple.product-type.app-extension`)
in an Xcode project that also builds the closed-source client. That project file
is not published, because it configures targets this licence does not cover. The
target's own build configuration is reproduced here **verbatim** instead, which
is what § 1 actually asks for — the settings that produced the object code.

Both configurations, copied from the project's `XCBuildConfiguration` blocks for
the `MorkeTunnel` target as of `MARKETING_VERSION = 26` / `CURRENT_PROJECT_VERSION = 0.2.6`:

```
CLANG_COVERAGE_MAPPING                  = NO
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = NO
CODE_SIGN_ENTITLEMENTS                  = MorkeTunnel/MorkeTunnel.entitlements
CODE_SIGN_IDENTITY                      = "Apple Development"
CODE_SIGN_STYLE                         = Automatic
CURRENT_PROJECT_VERSION                 = 0.2.6
DEVELOPMENT_TEAM                        = VM3XX8889Q
ENABLE_DEBUG_DYLIB                      = NO
GENERATE_INFOPLIST_FILE                 = NO
INFOPLIST_FILE                          = MorkeTunnel/Info.plist
INFOPLIST_KEY_CFBundleDisplayName       = Morke
IPHONEOS_DEPLOYMENT_TARGET              = 17.0
LD_RUNPATH_SEARCH_PATHS                 = ("$(inherited)",
                                           "@executable_path/Frameworks",
                                           "@executable_path/../../Frameworks")
MARKETING_VERSION                       = 26
PRODUCT_BUNDLE_IDENTIFIER               = tech.twodice.morke.tunnel
PRODUCT_NAME                            = "$(TARGET_NAME)"
SKIP_INSTALL                            = YES
SUPPORTED_PLATFORMS                     = "iphoneos iphonesimulator"
SUPPORTS_MACCATALYST                    = NO
SWIFT_APPROACHABLE_CONCURRENCY          = YES
SWIFT_OBJC_BRIDGING_HEADER              = MorkeTunnel/MorkeTunnel-Bridging-Header.h
SWIFT_STRICT_CONCURRENCY                = complete
SWIFT_VERSION                           = 6.0
TARGETED_DEVICE_FAMILY                  = 1
```

Debug and Release are identical apart from Apple's own configuration-level
defaults (optimisation level, `DEBUG` preprocessor flag, debug information
format), which the project inherits rather than sets per target.

**Three of these are load-bearing and will cost you a day if you change them:**

- **`ENABLE_DEBUG_DYLIB = NO`.** Xcode 16+ splits an app's main binary into a
  debug dylib by default. With it on, the extension fails to launch.
- **`GENERATE_INFOPLIST_FILE = NO` + the checked-in `Info.plist`.** The plist
  must set `CFBundlePackageType = XPC!`. A generated plist does not, and the
  extension then crashes at launch on iOS 26 with a message that points nowhere
  near the cause.
- **No `SWIFT_DEFAULT_ACTOR_ISOLATION`.** The rest of the tree defaults to
  `MainActor`; this target must not. Every `LibboxPlatformInterface` method is
  called from a Go goroutine on an arbitrary C thread, and a `MainActor` default
  turns each of those into an isolation violation.

### Bundle configuration

`Info.plist` (checked in, not generated):

```xml
<key>CFBundlePackageType</key>       <string>XPC!</string>
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.networkextension.packet-tunnel</string>
  <key>NSExtensionPrincipalClass</key>
  <string>PacketTunnelProvider</string>
</dict>
```

`PacketTunnelProvider` is pinned with `@objc(PacketTunnelProvider)` so
`NSExtensionPrincipalClass` resolves regardless of the Swift module name.

`MorkeTunnel.entitlements`:

```xml
com.apple.developer.networking.networkextension = [packet-tunnel-provider]
com.apple.security.application-groups          = [group.tech.twodice.morke]
keychain-access-groups                         = [$(AppIdentifierPrefix)tech.morke.shared]
```

These identifiers are contracts, not preferences. `AppGroup.appGroupID`,
`SharedKeychain`'s access-group suffix and `TunnelExtensionConstants.bundleID`
must each match their entitlement string exactly; a mismatch produces
`errSecItemNotFound` at tunnel start and no compile error at all. Rebuilding
under your own Team ID means changing all of the identifiers above consistently.

### What the target links

| Link | Kind |
|---|---|
| `Libbox.xcframework` | vendored, built in § 2 above (static `ar` archive) |
| `MorkeShared` | the SwiftPM module in this repository |
| `NetworkExtension.framework` | system |
| `UIKit.framework` | system |
| `libresolv.tbd` | system |

**Nothing else may be added to this list.** The Packet-Tunnel process runs under
a tight memory budget, so the extension's link set is a budget, not a module
boundary. `MorkeShared` in particular depends on Foundation, Security and (on
iOS) CryptoKit — all system frameworks — and on **zero** packages.

### Building `MorkeShared`

`MorkeShared/` is a SwiftPM library target with no dependencies. To build it
standalone, place it under `Sources/MorkeShared/` in a package declaring:

```swift
// swift-tools-version: 6.2
.library(name: "MorkeShared", targets: ["MorkeShared"])
.target(name: "MorkeShared")
```

with platforms `.iOS(.v17)`, `.macOS(.v14)`. In the Morke tree it is one target
of a larger local package; the target itself has no package dependencies, so
that declaration is complete.

---

## 4. macOS

The same sources also build `MorkeTunnel (macOS)` as a **system extension**
rather than an app extension, with `MorkeTunnel-macOS.entitlements` and a
separate `Info.plist`, and with an executable host (`main.swift`) that is not
part of this repository's perimeter because it is not compiled into the iOS
appex. The one behavioural difference the sources encode is that the macOS
system extension runs sandboxed **as root**, where `SecItem` returns
`errSecNotAvailable` — so on macOS the tunnel configuration travels in
`providerConfiguration`, and on iOS it lives in the shared Keychain with only a
non-secret marker in `providerConfiguration`. `AppGroup` and
`PacketTunnelProvider` both carry that split.

---

## 5. What is deliberately absent

This repository contains no network client. The extension has no `URLSession`,
no API base URL and no credential of its own; it reads a configuration the app
placed for it and hands it to libbox. That is a verifiable property of the
shipped binary as well as of this source — see
[README.md § Provenance](README.md#provenance-and-what-it-does-not-prove).
