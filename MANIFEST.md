# Export manifest

The definitive statement of what this repository contains, why each file is in
it, and how to regenerate it from the Morke source tree deterministically.

Two audiences. If you received this repository, it tells you the source set is
complete and lets you verify it. If you maintain it, it is the rule that decides
whether a new file belongs here — and the rule matters more than the list below,
because the list changes.

---

## The membership rule

> A file belongs in this repository **if and only if** it is either
>
> **(1)** compiled or linked into `MorkeTunnel.appex`, or
> **(2)** required to generate, install or run that object code — bundle
> configuration, entitlements, privacy manifest, and the build recipe and
> settings.
>
> Nothing else. Not proximity in the source tree, not shared authorship, not
> "it seemed related".

Limb (1) is GPLv3 § 5(c): *"You must license the entire work, as a whole, under
this License to anyone who comes into possession of a copy … regardless of how
they are packaged."* Applied to a static link, that reaches everything compiled
into the extension.

Limb (2) is GPLv3 § 1: Corresponding Source is *"all the source code needed to
generate, install, and … run the object code and to modify the work, including
scripts to control those activities."* A privacy manifest and an entitlements
file are not source code in the everyday sense, but without them the object code
cannot be generated or installed, so they are inside the definition.

**Applying the rule when something changes:**

- A new file in `MorkeTunnel/` → in, automatically. That directory is a
  file-system-synchronized Xcode group: every file added to it joins the target
  without anyone editing the project.
- A new file in `MorkeShared/` → in. The whole module is linked.
- A new module linked by the extension → the whole module joins the perimeter,
  and its own licence position has to be settled before it does. Adding one is
  also constrained independently: the extension's link set is a Packet-Tunnel
  memory budget, not a module boundary.
- A file that the app links but the extension does not → **out**. That is the
  entire closed half of the tree and it stays closed.
- Renaming or moving a file inside the perimeter → still in; update the list.

---

## Resolved list — 2026-09-04

Left column is the path **in this repository**. `MorkeShared/` is published flat;
in the Morke tree it lives at `MorkeKit/Sources/MorkeShared/`. Nothing else is
remapped.

### A. Compiled into the extension — GPLv3 § 5(c)

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/PacketTunnelProvider.swift` | `cf80648a…56d78e` | 355 |
| `MorkeTunnel/SingBoxTunnel.swift` | `a95b7fa1…6d1014` | 203 |
| `MorkeTunnel/ExtensionPlatformInterface.m` | `e27055e9…168479` | 733 |
| `MorkeTunnel/ExtensionPlatformInterface.h` | `3674c4c1…447ed0` | 57 |
| `MorkeTunnel/MorkeTunnelNetHelpers.c` | `4458fc8b…add071` | 116 |
| `MorkeTunnel/MorkeTunnelNetHelpers.h` | `c92c92bf…5ab7d9` | 91 |
| `MorkeTunnel/MorkeTunnel-Bridging-Header.h` | `f6a7ac93…90f734` | 29 |
| `MorkeShared/AppGroup.swift` | `bc693a37…017d65` | 234 |
| `MorkeShared/MorkeLog.swift` | `7b32cfe7…4693cb` | 59 |
| `MorkeShared/SharedKeychain.swift` | `d959d9b3…84e6b1` | 329 |
| `MorkeShared/SingBoxConfig.swift` | `459f7c60…929e69` | 55 |
| `MorkeShared/TunnelDiagnostics.swift` | `34ab658f…171161` | 174 |
| `MorkeShared/TunnelExtensionConstants.swift` | `3bafa2cf…983724` | 59 |

**13 files, 2 494 lines.**

> **On that number.** The perimeter was measured at **2 079 lines** on
> 2026-09-04 *before* the GPLv3 § 5(b) notices were written into these files;
> that figure is re-measured here and confirmed exactly. Adding the notices —
> 25 lines to each of the 7 tunnel files, 40 to each of the 6 `MorkeShared`
> files — took it to **2 494**. Both numbers are correct for their moment;
> neither supersedes the other. Quote 2 079 when talking about the size of the
> code, 2 494 when talking about the size of the files.

### B. Build inputs — GPLv3 § 1, required for the shipped iOS extension

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/Info.plist` | `bfba577a…0861cb` | 31 |
| `MorkeTunnel/MorkeTunnel.entitlements` | `9f4f660b…28e1ec` | 18 |
| `MorkeTunnel/PrivacyInfo.xcprivacy` | `de34a393…cd93c7` | 102 |

These three are in the perimeter under limb (2) of the rule, and this is a
reading, not a copy of somebody's list: without the `Info.plist` there is no
`CFBundlePackageType = XPC!` and the extension will not launch; without the
entitlements it cannot claim the packet-tunnel provider point or reach its App
Group. They are required to generate and install the object code, so § 1 reaches
them. They contain no secret.

The complete build-settings table is in [BUILD.md](BUILD.md) § 3 rather than in a
project file, because the Xcode project also configures targets this licence does
not cover. That is the one place where a strict reader could ask for more; the
settings themselves are reproduced verbatim, which is the substance of what § 1
asks for.

### C. macOS build inputs — included, not yet owed

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/MorkeTunnel-macOS.entitlements` | `93dc4089…9037d4` | 24 |
| `macOS/MorkeTunnel-macOS-Info.plist` | `17d0dea4…e47169` | 55 |

The same sources also build a macOS **system extension**. That build is not
conveyed today — only the iOS application ships — so these two are not yet owed
under § 6. They are published anyway, because the sources here already encode the
macOS behavioural split and withholding the two files that make it buildable
would leave the recipient with source that does not build for a platform it
plainly supports. In the Morke tree the second file lives at
`Config/MorkeTunnel-macOS-Info.plist`; `Config/` also holds the closed app's own
build configuration, so only that one file is exported and it is remapped to
`macOS/`.

**When the macOS application is conveyed, these move to block B and the
`MorkeTunnel (macOS)` target's build settings must be added to BUILD.md § 4.**
That is the one foreseeable change to this manifest that is an obligation rather
than tidiness.

### D. Authored for this repository

`LICENSE` · `README.md` · `BUILD.md` · `MANIFEST.md`

Not exported from the Morke tree; written for publication. `LICENSE` carries a
scope notice followed by the verbatim GNU GPL v3 text — its GPL body is
byte-identical to the copy the application ships in
**Settings → Legal → Open-source licences**, which is checkable:

```sh
tail -n 674 LICENSE | shasum -a 256
# 8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
```

### E. Excluded, deliberately

| Not published | Why |
|---|---|
| `Morke.xcodeproj/` | configures targets outside the perimeter; the covered target's settings are reproduced verbatim in BUILD.md instead |
| `Frameworks/Libbox.xcframework` | a ~100 MB build product, not source. Rebuild it from tag `v1.13.13` by BUILD.md § 2 |
| `MorkeKit/Sources/{MorkeFeatures,MorkeServices,MorkeModels,MorkeGlobe,MorkeDesignSystem,PlatformKit}` | linked by the app, never by the extension |
| `MorkeTunnelMac/main.swift` | the macOS system-extension executable host; not compiled into the iOS appex |
| `MorkeTunnelTests/`, every other test target | not compiled into the extension |
| `Config/Debug.xcconfig`, `Config/Release.xcconfig` | the app's configuration, and gitignored locally |
| `.DS_Store` | Finder metadata. Present in `MorkeTunnel/` on macOS; it is not source and must not be exported |
| `Docs/`, `store/`, `scripts/` | internal working documents and tooling |

---

## Verifying this repository

Every file in blocks A–C, in one command from the repository root:

```sh
find MorkeTunnel MorkeShared macOS -type f ! -name '.DS_Store' -print0 \
  | LC_ALL=C sort -z | xargs -0 shasum -a 256
```

Compare against the tables above. A digest that does not match means the file
changed after this manifest was written — which is the point of recording them.
They date the snapshot; they are a change detector, not a promise about any
binary. What the digests **cannot** tell you is whether this source built the
`.ipa` you downloaded: see [README.md § Provenance](README.md#provenance-and-what-it-does-not-prove).

## Regenerating this repository from the Morke tree

Run from the root of the Morke source tree, with `$OUT` an empty directory:

```sh
mkdir -p "$OUT/MorkeTunnel" "$OUT/MorkeShared" "$OUT/macOS"

# A + B + C — everything in MorkeTunnel/ except Finder metadata
find MorkeTunnel -type f ! -name '.DS_Store' -exec cp {} "$OUT/MorkeTunnel/" \;

# A — the shared module, published flat
cp MorkeKit/Sources/MorkeShared/*.swift "$OUT/MorkeShared/"

# C — the one macOS build input that lives outside MorkeTunnel/
cp Config/MorkeTunnel-macOS-Info.plist "$OUT/macOS/"

# D — the authored files
cp publish/tunnel-source/{LICENSE,README.md,BUILD.md,MANIFEST.md} "$OUT/"
```

The first `find` is the rule expressed as a command: `MorkeTunnel/` is a
file-system-synchronized Xcode group, so its contents and the target's contents
are the same set by construction. That is why the export is a directory copy and
not a hand-kept file list — a hand-kept list is what goes stale.

**Then, before publishing, re-run the safety sweep.** It is not a formality; it
is what stands between this repository and a leaked credential:

```sh
grep -rniE 'api\.morkenet|morkenet\.com|https?://|apiKey|secret|password|token' "$OUT"
grep -rn 'URLSession' "$OUT"
```

Expected on 2026-09-04: no live secret, no API base URL, and no `URLSession`
anywhere — the extension makes no control-plane call at all. The `https://`
matches are Apple's plist DTD declarations, links in comments, and the GPL's own
`gnu.org` URL. One real identifier is present and is published knowingly: the
Apple Team ID `VM3XX8889Q`, in `MorkeShared/SharedKeychain.swift`, as a
documented fallback Keychain access-group prefix. See
[README.md § A note on the Apple Team ID](README.md#a-note-on-the-apple-team-id).
