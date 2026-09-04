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
import Libbox
import os
import MorkeShared

private let singBoxErrorDomain = "SingBoxTunnel"

// Minimal sing-box engine wrapper for the Network Extension target.
// Vendored engine: sing-box v1.13.13 — see docs/singbox-integration.md and Frameworks/LIBBOX_VERSION.
// Owns the LibboxCommandServer lifecycle: setup → start → stop.
//
// @unchecked Sendable: all mutable state (commandServer, platformInterface, stopped) is guarded
// by `lock` (see below), and the class is purpose-built for cross-thread use — start() runs on a
// background queue while stop/pause/wake run on the NE provider queue. The lock supplies the
// happens-before AND (via `stopped`) the start↔stop ordering, so the type is genuinely safe to
// share; this is a real conformance, not a checker silencer.
final class SingBoxTunnel: @unchecked Sendable {

    // commandServer/platformInterface are written on a background queue (start() runs
    // on DispatchQueue.global from PacketTunnelProvider) and read/cleared on the NE
    // provider queue (stop/pause/wake). Guard the pointer get/set with an unfair lock
    // so the cross-thread access has a defined happens-before and ARC cannot over-release
    // a field mid-teardown. The lock protects ONLY the pointers — every libbox call is
    // made on a local copy taken OUTSIDE the lock, preserving the deadlock-safe design
    // where box.start() (and openTun's semaphore wait) runs off the provider queue.
    private let lock = OSAllocatedUnfairLock()
    private var commandServer: LibboxCommandServer?
    private var platformInterface: ExtensionPlatformInterface?
    // One-way lifecycle latch (T-CFG-28, NE audit F-1/F-4): the lock gives memory safety but
    // not ordering — the OS can deliver stopTunnel while start() is still mid-flight (VPN
    // toggled off during a slow connect; NE start-timeout). stop() latches this under the lock
    // as it detaches the fields, so it wins the race deterministically; start() re-checks it
    // under the lock at every publication/use point and aborts instead of publishing onto (or
    // starting the engine of) a stopped tunnel. libbox v1.13.13 has no closed-state guard of
    // its own: a post-close start()/startOrReloadService() resurrects a zombie engine or
    // panics on the closed subscriber channels. The checks shrink the race window to the few
    // instructions between a check and the following libbox call — it cannot be zero without
    // holding the lock across libbox (forbidden: deadlock). start() runs at most once per
    // extension process, so the latch never needs resetting.
    private var stopped = false

    // Initialises libbox, creates the command server, and starts the engine from a JSON config.
    // Must be called from startTunnel(_:completionHandler:).
    func start(configJSON: String, provider: NEPacketTunnelProvider) throws {
        let iface = ExtensionPlatformInterface(provider: provider)
        // Lifecycle guard 1: stop() already won (e.g. stopTunnel landed before this block ran —
        // F-4). Nothing was published, so stop() saw nils and tore nothing down: reset the
        // local iface (never started, defensive no-op) and back out. Aborts return cleanly, not
        // throw: the provider's late completion(nil) on an already-stopping session is ignored
        // by the OS, and the stop path owns all teardown.
        lock.lock()
        if stopped {
            lock.unlock()
            iface.reset()
            return
        }
        platformInterface = iface
        lock.unlock()

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.appGroupID
        ) else {
            throw NSError(domain: singBoxErrorDomain, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container not found — check entitlements"])
        }

        let setupOpts = LibboxSetupOptions()
        setupOpts.basePath    = container.path
        setupOpts.workingPath = container.appendingPathComponent("Working").path
        setupOpts.tempPath    = container.appendingPathComponent("Library/Caches").path
        // Bounded in-memory log ring. Trim it in Release to claw back headroom under the
        // tight NE budget (it only feeds libbox's unused log-subscription feature); keep
        // deeper scrollback in Debug for on-device diagnosis. CONFIRM the resident delta
        // on device (NE memory gauge) — the NE does not run in the Simulator.
#if DEBUG
        setupOpts.logMaxLines = 3000
#else
        setupOpts.logMaxLines = 512
#endif
        // In-process memory hardening for the tight NE budget (Packet-Tunnel tier ~50 MiB on
        // iOS 15+; see roadmap T-CFG-16). Two knobs:
        //  (1) oomKillerEnabled: libbox's own OOM killer, so the engine self-limits rather than
        //      leaving the OS as the only backstop.
        //  (2) oomMemoryLimit: an explicit byte ceiling. Left 0 (unset) before T-CFG-30, and 0's
        //      meaning (a sane NE default vs. no effective ceiling / no Go GC soft-limit) is not
        //      determinable from the vendored binary, so we set it. Derived AT RUNTIME (CLAUDE.md:
        //      never hardcode) from os_proc_available_memory() (os/proc.h, iOS 13+), the bytes this
        //      process can still allocate before jetsam: read here pre-engine it approximates the
        //      whole headroom. Give libbox 75% and keep 25% as the buffer that both absorbs the
        //      non-Go footprint (NE framework, ObjC/Swift) and makes libbox's GC/killer reclaim
        //      BEFORE jetsam kills the NE (under the kill switch a jetsam-kill lands in the
        //      T-QA-23 crash-gap). The 75% split is PROVISIONAL: the profiled peak-under-load
        //      number is the oldest-iOS-17 device run under T-CFG-16, which replaces it. A
        //      degenerate reading (0 or implausibly small: unsupported context, or already near
        //      the ceiling) skips the limit rather than strangling throughput with a tight one.
        setupOpts.oomKillerEnabled = true
        // os_proc_available_memory() (os/proc.h) is iOS/tvOS/watchOS-only. iOS derives the ceiling
        // from live jetsam headroom (rationale above); a macOS system extension has no comparable
        // jetsam budget and the symbol is unavailable there, so skip the explicit limit and rely on
        // oomKillerEnabled alone. The iOS branch is unchanged — byte-identical to the pre-macOS build.
#if os(iOS)
        let availableBytes = os_proc_available_memory()
        if availableBytes > (8 << 20) {  // 8 MiB floor: below this, treat the reading as unusable
            setupOpts.oomMemoryLimit = Int64(availableBytes) * 3 / 4
        }
#endif

        var setupErr: NSError?
        LibboxSetup(setupOpts, &setupErr)
        if let e = setupErr { throw e }

        var createErr: NSError?
        let server = LibboxNewCommandServer(iface, iface, &createErr)
        if let e = createErr { throw e }
        guard let server else {
            throw NSError(domain: singBoxErrorDomain, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }
        // Lifecycle guard 2: a stop() during setup already detached + reset the published
        // platformInterface and saw commandServer == nil. The local server was never published
        // or started, so close() alone releases it — nothing stop() touched is double-freed.
        lock.lock()
        if stopped {
            lock.unlock()
            server.close()
            return
        }
        commandServer = server
        lock.unlock()

        // Lifecycle guards 3+4: from here the server IS published — a racing stop() detaches
        // it and owns the full teardown (closeService/reset/close). On abort start() must NOT
        // touch the server again (a second close() would re-close the Go subscriber channels:
        // panic); a plain return is the correct local cleanup.
        lock.lock()
        if stopped { lock.unlock(); return }
        lock.unlock()
        try server.start()

        lock.lock()
        if stopped { lock.unlock(); return }
        lock.unlock()
        try server.startOrReloadService(configJSON, options: LibboxOverrideOptions())
    }

    // Stops the engine and releases all libbox resources.
    func stop() {
        // Detach the pointers under the lock, then tear down on the locals OUTSIDE it
        // (never hold the lock across libbox calls). Swapping to locals also makes stop()
        // idempotent — a re-entrant stop (e.g. serviceStop → cancelTunnelWithError) sees
        // nil and no-ops instead of double-closing. Latching `stopped` in the same critical
        // section makes a mid-flight start() abort at its next guard (F-1/F-4): whatever
        // stop() detaches here it tears down; whatever was not yet published stays local
        // to start(), which cleans it up itself.
        lock.lock()
        stopped = true
        let server = commandServer
        let iface  = platformInterface
        commandServer = nil
        platformInterface = nil
        lock.unlock()

        try? server?.closeService()
        iface?.reset()          // must run before close() — see ExtensionPlatformInterface.h
        server?.close()
    }

    // Forward NEPacketTunnelProvider sleep/wake to libbox so it can pause keepalives.
    // Read the pointer under the lock, then call libbox on the local copy outside it.
    func pause() {
        lock.lock(); let server = commandServer; lock.unlock()
        server?.pause()
    }
    func wake() {
        lock.lock(); let server = commandServer; lock.unlock()
        server?.wake()
    }
}
