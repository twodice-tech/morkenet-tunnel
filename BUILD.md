# Building the Morke tunnel extension

This file is part of the Corresponding Source. GPLv3 § 1 defines it as *"all the
source code needed to generate, install, and … run the object code and to modify
the work, **including scripts to control those activities**"* — so the build
recipe is owed, not merely helpful. Everything needed to go from this repository
plus a sing-box checkout to a loadable `MorkeTunnel.appex` is written down here.

Read [README.md](README.md) first for what this repository is and is not.

---

## 1. The pin

**sing-box `v1.13.13`, plus the Morke patch series** — upstream tag `v1.13.13` in
[`SagerNet/sing-box`](https://github.com/SagerNet/sing-box/tree/v1.13.13), commit
`83b73048ff772b919af18653b78ffeaa2d48b66e`, with `singbox-fork/0001-morke-trim.patch`
applied on top.

**We build a modified sing-box, and say so here because GPLv3 § 5(a) requires it.**
The patch is dated `2026-09-04`, every file it touches carries a modification
notice in its own header, and § 2 below is the recipe that turns the upstream tag
plus that patch into the exact engine we ship. The upstream tag alone will **not**
reproduce our artefact — see § 2.4.

| Artefact | Value |
|---|---|
| Upstream tag | `v1.13.13` |
| Upstream commit | `83b73048ff772b919af18653b78ffeaa2d48b66e` |
| Patch | `singbox-fork/0001-morke-trim.patch` |
| Patch SHA-256 | `295f7a3e86fb887855cd5f84426f142e49d3666f9bbee435799b3446c9adb5b5` |
| Version stamped into `constant.Version` | `1.13.13-morke.1` |

### What the patch changes, and why

Three files. Nothing is added to the engine; the patch only removes reachable
surface and records that it did.

- **`include/registry.go`** — the protocol registry. Upstream registers every
  protocol it ships. Morke's client refuses all but four egress types
  (`vless`, `direct`, `block`, `dns`), one ingress type (`tun`), no `endpoints` at
  all, and no `experimental` key but `cache_file`, in a fail-closed check that runs
  before any configuration reaches libbox. Everything outside that set was
  unreachable code in a shipped build, so it is no longer registered: the SOCKS,
  HTTP, mixed, Shadowsocks, VMess, Trojan, ShadowTLS, AnyTLS, redirect and TProxy
  inbounds; the SOCKS, HTTP, Shadowsocks, VMess, Trojan, Tor, SSH, ShadowTLS,
  AnyTLS, selector and urltest outbounds; the `ssm-api` service; the
  `cloudflare-origin-ca` certificate provider. An unexpected type now fails to
  decode instead of being constructed.
- **`cmd/internal/build_libbox/main.go`** — the build script. The optional-feature
  tags drop to `with_gvisor,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0`
  (+ `grpcnotrace` on Darwin, + `with_low_memory` off macOS), the Apple bind target
  drops the two tvOS slices nothing links, and the version stamp stops shelling out
  to `git describe` so the build no longer depends on VCS state.
- **`cmd/internal/sizeprobe/main.go`** — new, 14 lines. A `main` package that
  imports nothing but `experimental/libbox`, so the effect of a tag or registry
  change on the linked set can be measured in seconds instead of a full
  `gomobile bind`. Not required to build the extension; published because it is
  how the removals above were verified.

### Tags kept, and one kept deliberately

`with_gvisor` is required: the iOS kill switch sets `includeAllNetworks`, with which
sing-box's `system` and `mixed` TUN stacks are incompatible, so `tun.stack` becomes
`gvisor`. `with_utls` is required: REALITY is built on uTLS, and removing it removes
the proxy.

**`with_clash_api` is retained, and that is not an oversight.** Turning it off breaks
every start. `daemon/instance.go` passes a `PlatformLogWriter` to `box.New`
unconditionally; `box.go` treats a non-nil `PlatformLogWriter` as *needs the Clash
API*, calls `experimental.NewClashServer`, and without the tag that constructor is
nil and returns `os.ErrInvalid` — so `box.New` fails with
`create clash-server: invalid argument`. Unlinking the package would additionally
require editing `daemon/started_service.go`, which imports `experimental/clashapi`
with no build tag at all. Neither change is in this patch. The Clash control server
is nonetheless unreachable in the shipped product: it is only constructed from an
`experimental.clash_api` block, and the client refuses any `experimental` key but
`cache_file` before the configuration is handed to libbox.

---

## 2. Build `Libbox.xcframework` from source

No prebuilt releases exist; the framework is built from the pinned tag plus the patch.

**Prerequisites**

- Go ≥ 1.22 — the published artefact was built with **go1.26.4 darwin/arm64**
- Xcode with the full command-line tools — `xcode-select -p` must point at
  `Xcode.app`, not at the CommandLineTools stub. The published artefact was built
  with **Xcode 26.4.1 (17E202)**.

> **sing-box uses its own gomobile fork** (`github.com/sagernet/gomobile`),
> installed by `make lib_install` — pinned at `v0.1.12`. Upstream
> `golang.org/x/mobile/cmd/gomobile` is **incompatible**. The Makefile target is
> **`lib_apple`** — there is no `lib_ios` target.

### 2.1 The recipe

```sh
git clone --branch v1.13.13 https://github.com/SagerNet/sing-box.git
cd sing-box
git checkout 83b73048ff772b919af18653b78ffeaa2d48b66e

# 1. Apply the Morke patch series
patch -p1 < <path-to-this-repo>/singbox-fork/0001-morke-trim.patch

# 2. Install SagerNet's gomobile/gobind fork into GOPATH/bin
make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"

# 3. Build the Apple xcframework (iOS device + simulator, macOS)
#    Runs: go run ./cmd/internal/build_libbox -target apple
#    Takes several minutes; downloads many Go modules on first run.
make lib_apple

# 4. Place the output where the Xcode project expects it
find . -maxdepth 2 -name "Libbox.xcframework"
mv Libbox.xcframework <morke-tree>/Frameworks/Libbox.xcframework
```

`gomobile` itself is BSD-3-Clause. Its licence governs the **tool**, not the
sing-box code it wraps; the output is GPL-3.0-or-later like its input.

### 2.2 What it produces

Three slices, not five. Upstream's `build_libbox` also emits `tvos-arm64` and
`tvos-arm64_x86_64-simulator`; there is no tvOS target in the Xcode project, so
those two were never linked into any shipped binary.

| Slice | `Libbox` (static library) |
|---|---|
| `ios-arm64` | 41 759 144 bytes |
| `ios-arm64_x86_64-simulator` | 81 359 344 bytes |
| `macos-arm64_x86_64` | 108 408 328 bytes |

**The product is a static library.**
`Libbox.xcframework/ios-arm64/Libbox.framework/Libbox` is an `ar` archive —
`file(1)` says so. There is no dynamic-linking ambiguity here, which is why
§ 5(c) reaches the whole extension.

### 2.3 Verifying the artefact — this build IS reproducible

Two builds of this source, from different directories on different runs, produce
`Libbox` files that are **identical except for three bytes**: the ASCII mtime that
`libtool` stamps into the `__.SYMDEF` member header of the `ar` archive. Blank the
member mtimes and the digest is stable.

`singbox-fork/libbox-digest.py` does exactly that and nothing else — 40 lines,
stdlib only, no network, readable in a minute:

```sh
python3 singbox-fork/libbox-digest.py \
  Libbox.xcframework/*/Libbox.framework/Versions/A/Libbox
```

Expected, for the engine shipped with this tag:

| Slice | Canonical SHA-256 |
|---|---|
| `ios-arm64` | `914762d253683aa3dd6e3aa8c05dced89b376cb5f848fda727f6db781863e9c4` |
| `ios-arm64_x86_64-simulator` | `9da5ded81a894e46eac647e0d616cc21f0f6dcbf851db477af0d380d757a2b26` |
| `macos-arm64_x86_64` | `e37d577ee6b8b9936f824c6968cb2cd8a1868346c8ed85b86eba036f3f641f76` |

A plain `shasum -a 256` of the same files will **not** match between builds, by
exactly those three bytes per slice. That is a property of `libtool`, not of the
source.

### 2.4 If you build the upstream tag instead

You will get a different, larger artefact, and no digest above will match — that is
correct and expected. The upstream tag is the base, not the engine we ship. Apply
the patch.

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
