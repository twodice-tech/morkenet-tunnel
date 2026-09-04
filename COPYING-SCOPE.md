# Scope of the licence — read first

This notice is **not** part of the GNU General Public License. The licence text
itself is in [`LICENSE`](LICENSE), reproduced verbatim and unmodified, and it is
the only place the terms live. Nothing here adds to, removes from, or
reinterprets it.

It used to sit at the top of `LICENSE`. It was moved out on **2026-09-05**
because a preamble in front of the text defeats automatic licence detection —
GitHub matched the file against no known licence and reported the repository as
having none, which is the opposite of what a Corresponding Source repository
exists to say. Moving the notice changes nothing legally: the grant is in
`LICENSE` and in the per-file headers, and both are untouched.

---

## What this licence covers

**Every file in THIS repository**, under the **GNU General Public License,
version 3 or later**. That set is the Corresponding Source (GPLv3 § 1) of
`MorkeTunnel.appex`, the Network Extension inside the Morke VPN iOS and macOS
applications:

| Path | What it is |
|---|---|
| `MorkeTunnel/` | the extension's own sources, and the bundle configuration, entitlements and privacy manifest needed to generate and install it |
| `MorkeShared/` | the app↔extension surface module the extension links |
| `macOS/` | the one build input, outside `MorkeTunnel/`, that the macOS system-extension build needs |
| `singbox-fork/` | **our modification to sing-box**, as a patch against the upstream tag, plus the digest checker that verifies a rebuild |
| `LICENSE`, `README.md`, `BUILD.md`, `MANIFEST.md`, this file | written for publication: the licence text, the front page, the build recipe § 1 obliges us to give, and the manifest that states the membership rule |

[`MANIFEST.md`](MANIFEST.md) is the authority on *why* each file is in that set;
it carries the membership rule and the resolved list with digests.

The extension statically links [sing-box](https://github.com/SagerNet/sing-box),
which is licensed GPL-3.0-or-later. GPLv3 § 5(c) requires the entire work, as a
whole, to be licensed under the same terms to anyone who comes into possession of
a copy. That is why this repository exists and why it is GPL-3.0-or-later.

**The engine we ship is modified.** Since 2026-09-04 the extension links a
trimmed sing-box, not upstream's build, so the Corresponding Source is our
modified tree rather than the tag. `singbox-fork/0001-morke-trim.patch` is that
modification, and it is a derivative of sing-box: it carries sing-box's own
licence, GPL-3.0-or-later, exactly as the code it patches does. GPLv3 § 5(a)
requires us to state that the work is modified and to date it — that date is
**2026-09-04**, and every file the patch touches carries the notice in its own
header. See [`README.md`](README.md) and [`BUILD.md`](BUILD.md) § 1.

Copyright (C) 2026 Two Dice Ltd, for the files in this repository.
Copyright (C) 2022 by nekohasekai `<contact-sagernet@sekai.icu>`, and the other
sing-box contributors, for the engine this extension links. See
[`README.md` § Component licences](README.md#component-licences) for the
component licence inventory.

## What this licence does not cover

It does not reach anything outside this repository. In particular it does **not**
place under the GPL, and must not be read as placing under the GPL:

* the Morke iOS and macOS client applications and their app targets;
* the `MorkeFeatures`, `MorkeServices`, `MorkeModels`, `MorkeGlobe`,
  `MorkeDesignSystem` and `PlatformKit` modules;
* the Morke backend service, its API and its configuration;
* the Morke name, logo, icons, artwork and other brand assets, which are
  trademarks and are not licensed here at all.

Those are separate works. The client application links no GPL-licensed code; it
communicates with the extension through Apple's NetworkExtension inter-process
interfaces. This repository is deliberately not placed at the root of the wider
Morke source tree, because a root licence file would purport to cover all of it,
and that would be false.

## The one file set that is dual-licensed

`MorkeShared/` is our own code, and it is linked by **both** binaries — the GPL
extension and the closed-source client. As the copyright holder we license it
twice, which is ordinary:

* to you, and to every recipient of this repository or of the shipped extension,
  under the GNU General Public License v3 or later, on the terms in
  [`LICENSE`](LICENSE), unconditionally; and
* to ourselves, for use inside the closed-source client, under our own
  proprietary terms.

The second licence takes nothing away from the first. You may use `MorkeShared/`
under the GPL for anything the GPL allows. Each file in it carries the same
statement in its own header.

## Additional term carried by sing-box (GPLv3 § 7)

The upstream sing-box `LICENSE` appends the following, and we reproduce it
because § 4 requires notices to be kept intact:

> In addition, no derivative work may use the name or imply association
> with this application without prior consent.

This is a declining of trademark rights in the sense of GPLv3 § 7(e). It binds
any derivative of the engine. It does not restrict the freedoms granted by
[`LICENSE`](LICENSE).

## Our position is GPL-3.0-**or-later**, whatever the repository page says

`LICENSE` is the plain GNU GPL v3 text, and that text does not by itself choose
between *"version 3 only"* and *"version 3 or later"* — the choice is made by the
copyright holder in the per-file notices, which is where the GPL's own
instructions put it. Ours say **"either version 3 of the License, or (at your
option) any later version"**, in all 13 perimeter files, and upstream sing-box
says the same.

So an automatic detector reading only `LICENSE` may label this repository
**`GPL-3.0-only`**. That label is the detector's inference from a file that
cannot express the difference; it is not our grant. **The per-file headers are
authoritative, and they are not to be edited to agree with a badge.** If you are
relying on the "or later" option, rely on the headers and on this paragraph.

## No warranty

This program is distributed **WITHOUT ANY WARRANTY**; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See sections
15, 16 and 17 of [`LICENSE`](LICENSE).
