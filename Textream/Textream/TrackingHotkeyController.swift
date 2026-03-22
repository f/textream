//
//  TrackingHotkeyController.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import AppKit

protocol TrackingHotkeyControlling: AnyObject {
    var onToggleAside: (() -> Void)? { get set }
    var onHoldIgnoreChanged: ((Bool) -> Void)? { get set }
    var isRunning: Bool { get }

    func start()
    func stop()
}

final class TrackingHotkeyController: TrackingHotkeyControlling {
    static var shared: any TrackingHotkeyControlling = TrackingHotkeyController()

    var onToggleAside: (() -> Void)?
    var onHoldIgnoreChanged: ((Bool) -> Void)?

    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var lastOptionTapAt: Date?
    private var isFnActive = false
    private var optionIsDown = false

    static func installShared(_ controller: any TrackingHotkeyControlling) {
        shared = controller
    }

    static func resetShared() {
        shared = TrackingHotkeyController()
    }

    var isRunning: Bool {
        localFlagsMonitor != nil || globalFlagsMonitor != nil || localKeyMonitor != nil || globalKeyMonitor != nil
    }

    func start() {
        stop()

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
    }

    func stop() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        localFlagsMonitor = nil
        globalFlagsMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
        if isFnActive {
            isFnActive = false
            onHoldIgnoreChanged?(false)
        }
        optionIsDown = false
        lastOptionTapAt = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionDown = flags.contains(.option)
        if optionDown != optionIsDown {
            if optionDown {
                registerOptionTap()
            }
            optionIsDown = optionDown
        }

        let fnDown = flags.contains(.function)
        if fnDown != isFnActive {
            isFnActive = fnDown
            onHoldIgnoreChanged?(fnDown)
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard event.keyCode == 63 else { return } // fn/globe key
        if !isFnActive {
            isFnActive = true
            onHoldIgnoreChanged?(true)
        }
    }

    private func registerOptionTap() {
        let now = Date()
        if let lastTap = lastOptionTapAt, now.timeIntervalSince(lastTap) <= 0.35 {
            lastOptionTapAt = nil
            onToggleAside?()
        } else {
            lastOptionTapAt = now
        }
    }
}
