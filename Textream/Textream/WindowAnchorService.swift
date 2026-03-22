//
//  WindowAnchorService.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import Observation

enum WindowAnchorSource: String, Codable, CaseIterable, Identifiable {
    case accessibility
    case quartz
    case fallback
    case unavailable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accessibility: return "AX"
        case .quartz: return "Quartz"
        case .fallback: return "Fallback"
        case .unavailable: return "Unavailable"
        }
    }
}

struct AttachedWindowInfo: Identifiable, Hashable {
    let id: Int
    let ownerName: String
    let title: String
    let pid: pid_t
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool

    var displayName: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return ownerName
        }
        return "\(ownerName) — \(trimmedTitle)"
    }
}

struct WindowAnchorResolution {
    let frame: CGRect?
    let window: AttachedWindowInfo?
    let source: WindowAnchorSource
    let isAccessibilityTrusted: Bool
    let message: String

    var frameLabel: String {
        guard let frame else { return "-" }
        return "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }

    func with(
        source: WindowAnchorSource? = nil,
        frame: CGRect? = nil,
        message: String? = nil
    ) -> WindowAnchorResolution {
        WindowAnchorResolution(
            frame: frame ?? self.frame,
            window: window,
            source: source ?? self.source,
            isAccessibilityTrusted: isAccessibilityTrusted,
            message: message ?? self.message
        )
    }
}

enum AccessibilityPermissionState: String, Codable {
    case unknown
    case notGranted
    case granted

    var label: String {
        switch self {
        case .unknown: return "Checking"
        case .notGranted: return "Not Granted"
        case .granted: return "Granted"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "Textream is still checking whether Accessibility access is available."
        case .notGranted:
            return "Attached Overlay can only follow app windows precisely after Accessibility access is enabled."
        case .granted:
            return "Accessibility access is available for precise window geometry when macOS exposes it."
        }
    }
}

enum AttachedDiagnosticState: String, Codable {
    case inactive
    case noTargetSelected
    case permissionRequired
    case attachedLive
    case quartzFallback
    case targetUnreadable
    case targetLostFallback
    case hiddenFallback

    var label: String {
        switch self {
        case .inactive: return "Inactive"
        case .noTargetSelected: return "No Target"
        case .permissionRequired: return "Accessibility Off"
        case .attachedLive: return "Attached"
        case .quartzFallback: return "Visible Bounds Fallback"
        case .targetUnreadable: return "Window Unreadable"
        case .targetLostFallback: return "Window Lost"
        case .hiddenFallback: return "Hidden by Fallback"
        }
    }
}

private enum AttachedCopy {
    static let noTargetMessage = "Choose a target window to attach to. Until then, Textream will stay in the screen corner."
    static let noTargetStatusLine = "No target window selected; using screen corner"
    static let noTargetDetailLine = "Fallback • No window selected"

    static let permissionRequiredMessage = "Attached Overlay needs Accessibility access before it can follow another app window. Textream will stay in the screen corner until access is granted."
    static let permissionRequiredStatusLine = "Accessibility off; using screen corner"
    static let permissionRequiredDetailLine = "Open System Settings to allow Attached Overlay"

    static let quartzStatusLine = "Using visible window bounds (AX fallback)"

    static let targetLostStatusLine = "Target window lost; back to screen corner"
    static let targetUnreadableStatusLine = "Can't read selected window; using screen corner"
    static let hiddenStatusLine = "Target window unavailable; overlay hidden"

    static func liveMessage(for target: String) -> String {
        "Attached using Accessibility geometry for \(target)."
    }

    static func quartzMessage(for target: String) -> String {
        "Accessibility geometry is unavailable for \(target). Textream is following the visible window bounds instead."
    }

    static func quartzDetailLine(for target: String) -> String {
        "Quartz fallback • \(target)"
    }

    static func targetLostMessage(for target: String) -> String {
        "The selected window is no longer available. Textream moved back to the screen corner."
    }

    static func targetUnreadableMessage(for target: String) -> String {
        "Accessibility is enabled, but macOS is not exposing usable geometry for \(target). Textream is staying in the screen corner."
    }

    static func fallbackDetailLine(for target: String) -> String {
        "Fallback • \(target)"
    }

    static func hiddenMessage(for target: String) -> String {
        "The selected window is unavailable, so the overlay was hidden by the attached fallback setting."
    }

    static func hiddenDetailLine(for target: String) -> String {
        "Hidden fallback • \(target)"
    }
}

@Observable
final class AttachedDiagnosticsStore {
    static let shared = AttachedDiagnosticsStore()

    var permissionState: AccessibilityPermissionState = .unknown
    var state: AttachedDiagnosticState = .inactive
    var anchorSource: WindowAnchorSource = .unavailable
    var anchorSourceLabel: String = "Inactive"
    var anchorMessage: String = "Attached mode inactive"
    var statusLine: String = ""
    var detailLine: String = ""
    var frameLabel: String = "-"
    var targetWindowID: Int = 0
    var targetWindowLabel: String = ""
    var isDegraded: Bool = false
    var shouldOfferSystemSettings: Bool = false

    private var trackedTargetWindowID: Int = 0
    private var hasResolvedGeometryForTarget = false

    private var displayTargetLabel: String {
        let trimmed = targetWindowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the selected window" : trimmed
    }

    var userFacingExplanation: String {
        switch state {
        case .inactive:
            return permissionState.detail
        case .noTargetSelected:
            return "Pick a target window when you're ready. Until then, Attached Overlay stays in the screen corner."
        case .permissionRequired:
            return "Grant Accessibility in System Settings to let Textream follow another app window precisely. Until then, Attached Overlay stays in the screen corner."
        case .attachedLive:
            return "Textream is locked to \(displayTargetLabel) using Accessibility geometry."
        case .quartzFallback:
            return "macOS did not return Accessibility geometry for \(displayTargetLabel), so Textream is following the visible window bounds instead. Positioning can be approximate."
        case .targetUnreadable:
            return "Accessibility is on, but macOS is not exposing a usable frame for \(displayTargetLabel). Textream is staying in the screen corner so the overlay remains visible."
        case .targetLostFallback:
            return "The selected window disappeared or moved out of the available window list. Textream moved back to the screen corner so you can keep reading."
        case .hiddenFallback:
            return "The selected window disappeared and your fallback setting hides the overlay instead of pinning it to the screen corner."
        }
    }

    @discardableResult
    func refreshPermissionState(prompt: Bool = false) -> AccessibilityPermissionState {
        let trusted = WindowAnchorService.isAccessibilityTrusted(prompt: prompt)
        permissionState = trusted ? .granted : .notGranted
        return permissionState
    }

    func syncSelection(targetWindowID: Int, targetWindowLabel: String) {
        if trackedTargetWindowID != targetWindowID {
            trackedTargetWindowID = targetWindowID
            hasResolvedGeometryForTarget = false
        }
        self.targetWindowID = targetWindowID
        if !targetWindowLabel.isEmpty {
            self.targetWindowLabel = targetWindowLabel
        } else if targetWindowID == 0 {
            self.targetWindowLabel = ""
        }
    }

    func markInactive(message: String, targetWindowID: Int, targetWindowLabel: String) {
        syncSelection(targetWindowID: targetWindowID, targetWindowLabel: targetWindowLabel)
        refreshPermissionState()
        state = .inactive
        anchorSource = .unavailable
        anchorSourceLabel = "Inactive"
        anchorMessage = message
        statusLine = ""
        detailLine = ""
        frameLabel = "-"
        isDegraded = false
        shouldOfferSystemSettings = permissionState == .notGranted
    }

    func beginAttachedSession(targetWindowID: Int, targetWindowLabel: String) {
        syncSelection(targetWindowID: targetWindowID, targetWindowLabel: targetWindowLabel)
        let permission = refreshPermissionState()
        if targetWindowID == 0 {
            apply(
                state: .noTargetSelected,
                anchorSource: .fallback,
                message: AttachedCopy.noTargetMessage,
                statusLine: AttachedCopy.noTargetStatusLine,
                detailLine: AttachedCopy.noTargetDetailLine,
                frameLabel: "-",
                isDegraded: true,
                shouldOfferSystemSettings: permission == .notGranted
            )
        } else if permission == .notGranted {
            apply(
                state: .permissionRequired,
                anchorSource: .fallback,
                message: AttachedCopy.permissionRequiredMessage,
                statusLine: AttachedCopy.permissionRequiredStatusLine,
                detailLine: AttachedCopy.permissionRequiredDetailLine,
                frameLabel: "-",
                isDegraded: true,
                shouldOfferSystemSettings: true
            )
        } else {
            apply(
                state: .inactive,
                anchorSource: .unavailable,
                message: "Looking for the selected window geometry.",
                statusLine: "",
                detailLine: "",
                frameLabel: "-",
                isDegraded: false,
                shouldOfferSystemSettings: false
            )
        }
    }

    func updateResolution(
        _ resolution: WindowAnchorResolution,
        targetWindowID: Int,
        targetWindowLabel: String,
        overlayHidden: Bool
    ) {
        syncSelection(targetWindowID: targetWindowID, targetWindowLabel: targetWindowLabel)
        let permission = refreshPermissionState()

        anchorSource = resolution.source
        anchorSourceLabel = resolution.source == .unavailable && state == .inactive ? "Inactive" : resolution.source.label
        frameLabel = resolution.frameLabel
        if let window = resolution.window {
            self.targetWindowLabel = window.displayName
            self.targetWindowID = window.id
        }

        if targetWindowID == 0 {
            apply(
                state: .noTargetSelected,
                anchorSource: resolution.source == .unavailable ? .fallback : resolution.source,
                message: AttachedCopy.noTargetMessage,
                statusLine: AttachedCopy.noTargetStatusLine,
                detailLine: AttachedCopy.noTargetDetailLine,
                frameLabel: resolution.frameLabel,
                isDegraded: true,
                shouldOfferSystemSettings: permission == .notGranted
            )
            return
        }

        if permission == .notGranted {
            hasResolvedGeometryForTarget = false
            apply(
                state: .permissionRequired,
                anchorSource: .fallback,
                message: AttachedCopy.permissionRequiredMessage,
                statusLine: AttachedCopy.permissionRequiredStatusLine,
                detailLine: AttachedCopy.permissionRequiredDetailLine,
                frameLabel: resolution.frameLabel,
                isDegraded: true,
                shouldOfferSystemSettings: true
            )
            return
        }

        let displayTarget = self.targetWindowLabel.isEmpty ? "Selected window" : self.targetWindowLabel

        switch resolution.source {
        case .accessibility:
            hasResolvedGeometryForTarget = true
            apply(
                state: .attachedLive,
                anchorSource: .accessibility,
                message: AttachedCopy.liveMessage(for: displayTarget),
                statusLine: "",
                detailLine: "",
                frameLabel: resolution.frameLabel,
                isDegraded: false,
                shouldOfferSystemSettings: false
            )
        case .quartz:
            hasResolvedGeometryForTarget = true
            apply(
                state: .quartzFallback,
                anchorSource: .quartz,
                message: AttachedCopy.quartzMessage(for: displayTarget),
                statusLine: AttachedCopy.quartzStatusLine,
                detailLine: AttachedCopy.quartzDetailLine(for: displayTarget),
                frameLabel: resolution.frameLabel,
                isDegraded: true,
                shouldOfferSystemSettings: false
            )
        case .fallback, .unavailable:
            let message: String
            let statusLine: String
            let detailLine: String
            let nextState: AttachedDiagnosticState

            if overlayHidden {
                nextState = .hiddenFallback
                message = AttachedCopy.hiddenMessage(for: displayTarget)
                statusLine = AttachedCopy.hiddenStatusLine
                detailLine = AttachedCopy.hiddenDetailLine(for: displayTarget)
            } else if hasResolvedGeometryForTarget {
                nextState = .targetLostFallback
                message = AttachedCopy.targetLostMessage(for: displayTarget)
                statusLine = AttachedCopy.targetLostStatusLine
                detailLine = AttachedCopy.fallbackDetailLine(for: displayTarget)
            } else {
                nextState = .targetUnreadable
                message = AttachedCopy.targetUnreadableMessage(for: displayTarget)
                statusLine = AttachedCopy.targetUnreadableStatusLine
                detailLine = AttachedCopy.fallbackDetailLine(for: displayTarget)
            }

            hasResolvedGeometryForTarget = false
            apply(
                state: nextState,
                anchorSource: resolution.source == .unavailable ? .fallback : resolution.source,
                message: message,
                statusLine: statusLine,
                detailLine: detailLine,
                frameLabel: resolution.frameLabel,
                isDegraded: true,
                shouldOfferSystemSettings: false
            )
        }
    }

    private func apply(
        state: AttachedDiagnosticState,
        anchorSource: WindowAnchorSource,
        message: String,
        statusLine: String,
        detailLine: String,
        frameLabel: String,
        isDegraded: Bool,
        shouldOfferSystemSettings: Bool
    ) {
        self.state = state
        self.anchorSource = anchorSource
        self.anchorSourceLabel = anchorSource == .unavailable && state == .inactive ? "Inactive" : anchorSource.label
        self.anchorMessage = message
        self.statusLine = statusLine
        self.detailLine = detailLine
        self.frameLabel = frameLabel
        self.isDegraded = isDegraded
        self.shouldOfferSystemSettings = shouldOfferSystemSettings
    }
}

protocol WindowAnchorProviding {
    func isAccessibilityTrusted(prompt: Bool) -> Bool
    func openAccessibilitySettings()
    func visibleWindows() -> [AttachedWindowInfo]
    func accessibilityFrame(for target: AttachedWindowInfo) -> CGRect?
}

struct LiveWindowAnchorProvider: WindowAnchorProviding {
    static func desktopFrame(for screens: [NSScreen] = NSScreen.screens) -> CGRect {
        screens.reduce(CGRect.null) { partial, screen in
            partial.isNull ? screen.frame : partial.union(screen.frame)
        }
    }

    static func normalizeToAppKitCoordinates(_ rawFrame: CGRect, desktopFrame: CGRect? = nil) -> CGRect {
        guard !rawFrame.isEmpty else { return rawFrame }
        let desktopFrame = desktopFrame ?? Self.desktopFrame()
        guard !desktopFrame.isNull, !desktopFrame.isEmpty else { return rawFrame }

        // AX and Quartz window geometry use an upper-left desktop origin, while
        // AppKit panels are positioned in a lower-left desktop coordinate space.
        return CGRect(
            x: rawFrame.minX,
            y: desktopFrame.maxY - rawFrame.maxY,
            width: rawFrame.width,
            height: rawFrame.height
        )
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func visibleWindows() -> [AttachedWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let desktopFrame = Self.desktopFrame()

        return list.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let windowID = entry[kCGWindowNumber as String] as? Int else { return nil }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let ownerName = (entry[kCGWindowOwnerName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            let title = (entry[kCGWindowName as String] as? String) ?? ""
            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary
            let rawBounds = boundsDict.flatMap(CGRect.init(dictionaryRepresentation:)) ?? .zero
            let bounds = Self.normalizeToAppKitCoordinates(rawBounds, desktopFrame: desktopFrame)
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true

            guard !bounds.isEmpty, bounds.width > 120, bounds.height > 60 else { return nil }
            guard ownerName != "Window Server" else { return nil }

            return AttachedWindowInfo(
                id: windowID,
                ownerName: ownerName,
                title: title,
                pid: ownerPID,
                bounds: bounds,
                layer: layer,
                isOnScreen: isOnScreen
            )
        }
    }

    func accessibilityFrame(for target: AttachedWindowInfo) -> CGRect? {
        let appElement = AXUIElementCreateApplication(target.pid)
        var axWindowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindowsValue)
        guard result == .success, let axWindows = axWindowsValue as? [AXUIElement] else {
            return nil
        }
        let desktopFrame = Self.desktopFrame()

        let normalizedTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var bestFrame: CGRect?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for window in axWindows {
            var titleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
                continue
            }
            let positionAX = unsafeBitCast(positionValue, to: AXValue.self)
            let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)

            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionAX, .cgPoint, &point),
                  AXValueGetValue(sizeAX, .cgSize, &size) else {
                continue
            }
            if size.width > 0, size.height > 0 {
                let frame = Self.normalizeToAppKitCoordinates(
                    CGRect(origin: point, size: size),
                    desktopFrame: desktopFrame
                )
                let titlePenalty: CGFloat
                if normalizedTitle.isEmpty {
                    titlePenalty = 0
                } else {
                    titlePenalty = title == normalizedTitle ? 0 : 1200
                }
                let score = titlePenalty + frameDistance(frame, target.bounds)
                if score < bestScore {
                    bestScore = score
                    bestFrame = frame
                }
            }
        }

        return bestFrame
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let centerDelta = abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return centerDelta + sizeDelta
    }
}

final class WindowAnchorService {
    static var sharedProvider: any WindowAnchorProviding = LiveWindowAnchorProvider()
    static let trackingInterval: TimeInterval = 0.05

    var onResolutionChanged: ((WindowAnchorResolution) -> Void)?

    private var timer: AnyCancellable?
    private var lastWindowID: Int?
    private let provider: any WindowAnchorProviding

    init(provider: (any WindowAnchorProviding)? = nil) {
        self.provider = provider ?? Self.sharedProvider
    }

    deinit {
        stopTracking()
        onResolutionChanged = nil
    }

    static func installSharedProvider(_ provider: any WindowAnchorProviding) {
        sharedProvider = provider
    }

    static func resetSharedProvider() {
        sharedProvider = LiveWindowAnchorProvider()
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        sharedProvider.isAccessibilityTrusted(prompt: prompt)
    }

    static func openAccessibilitySettings() {
        sharedProvider.openAccessibilitySettings()
    }

    static func visibleWindows() -> [AttachedWindowInfo] {
        sharedProvider.visibleWindows()
    }

    func startTracking(windowID: Int) {
        stopTracking()
        lastWindowID = windowID
        timer = Timer.publish(every: Self.trackingInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.emitFrame()
            }
        emitFrame()
    }

    func stopTracking() {
        timer?.cancel()
        timer = nil
        lastWindowID = nil
    }

    var trackedWindowID: Int? { lastWindowID }

    func currentWindow() -> AttachedWindowInfo? {
        guard let lastWindowID else { return nil }
        return provider.visibleWindows().first(where: { $0.id == lastWindowID })
    }

    func resolution(for windowID: Int) -> WindowAnchorResolution {
        let trusted = provider.isAccessibilityTrusted(prompt: false)
        let visibleWindow = provider.visibleWindows().first(where: { $0.id == windowID })

        guard let visibleWindow else {
            return WindowAnchorResolution(
                frame: nil,
                window: nil,
                source: .unavailable,
                isAccessibilityTrusted: trusted,
                message: "Target window is no longer visible; using fallback placement"
            )
        }

        if trusted, let axFrame = provider.accessibilityFrame(for: visibleWindow) {
            return WindowAnchorResolution(
                frame: axFrame,
                window: visibleWindow,
                source: .accessibility,
                isAccessibilityTrusted: true,
                message: "Using Accessibility geometry for the selected window"
            )
        }

        let message = trusted
            ? "Accessibility lookup failed; using Quartz window bounds"
            : "Accessibility not authorized; using Quartz window bounds"
        return WindowAnchorResolution(
            frame: visibleWindow.bounds,
            window: visibleWindow,
            source: .quartz,
            isAccessibilityTrusted: trusted,
            message: message
        )
    }

    func emitCurrentResolution() {
        emitFrame()
    }

    func anchoredOrigin(
        targetFrame: CGRect,
        overlaySize: CGSize,
        corner: AttachedAnchorCorner,
        marginX: CGFloat,
        marginY: CGFloat,
        within visibleFrame: CGRect? = nil
    ) -> CGPoint {
        let visibleFrame = visibleFrame ?? screen(for: targetFrame, corner: corner)?.visibleFrame
        let origin: CGPoint

        switch corner {
        case .topLeft:
            origin = CGPoint(x: targetFrame.minX + marginX, y: targetFrame.maxY - overlaySize.height - marginY)
        case .topRight:
            origin = CGPoint(x: targetFrame.maxX - overlaySize.width - marginX, y: targetFrame.maxY - overlaySize.height - marginY)
        case .bottomLeft:
            origin = CGPoint(x: targetFrame.minX + marginX, y: targetFrame.minY + marginY)
        case .bottomRight:
            origin = CGPoint(x: targetFrame.maxX - overlaySize.width - marginX, y: targetFrame.minY + marginY)
        }

        return clampedOverlayOrigin(origin, overlaySize: overlaySize, within: visibleFrame)
    }

    func fallbackFrame(
        overlaySize: CGSize,
        corner: AttachedAnchorCorner,
        marginX: CGFloat,
        marginY: CGFloat,
        on screen: NSScreen? = NSScreen.main,
        within visibleFrame: CGRect? = nil
    ) -> CGRect {
        let activeVisibleFrame = visibleFrame
            ?? screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero
        let origin = anchoredOrigin(
            targetFrame: activeVisibleFrame,
            overlaySize: overlaySize,
            corner: corner,
            marginX: marginX,
            marginY: marginY,
            within: activeVisibleFrame
        )
        return CGRect(origin: origin, size: overlaySize)
    }

    func screen(for targetFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var bestScreen: NSScreen?
        var bestIntersectionArea: CGFloat = 0

        for screen in screens {
            let intersection = screen.frame.intersection(targetFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestScreen = screen
            }
        }

        if let bestScreen, bestIntersectionArea > 0 {
            return bestScreen
        }

        let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        return screens.min { lhs, rhs in
            squaredDistance(from: center, to: lhs.visibleFrame) < squaredDistance(from: center, to: rhs.visibleFrame)
        }
    }

    func screen(for targetFrame: CGRect, corner: AttachedAnchorCorner) -> NSScreen? {
        let anchorPoint = anchorPoint(for: targetFrame, corner: corner)
        let screens = NSScreen.screens

        if let containingScreen = screens.first(where: { $0.frame.contains(anchorPoint) }) {
            return containingScreen
        }

        return screens.min { lhs, rhs in
            squaredDistance(from: anchorPoint, to: lhs.frame) < squaredDistance(from: anchorPoint, to: rhs.frame)
        } ?? screen(for: targetFrame)
    }

    private func emitFrame() {
        guard let lastWindowID else { return }
        onResolutionChanged?(resolution(for: lastWindowID))
    }

    private func clampedOverlayOrigin(_ origin: CGPoint, overlaySize: CGSize, within visibleFrame: CGRect?) -> CGPoint {
        guard let visibleFrame, !visibleFrame.isEmpty else { return origin }

        let maxX = max(visibleFrame.minX, visibleFrame.maxX - overlaySize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - overlaySize.height)

        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    private func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, frame.minX), frame.maxX)
        let clampedY = min(max(point.y, frame.minY), frame.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func anchorPoint(for targetFrame: CGRect, corner: AttachedAnchorCorner) -> CGPoint {
        let insetX = min(1, max(0, targetFrame.width / 4))
        let insetY = min(1, max(0, targetFrame.height / 4))

        switch corner {
        case .topLeft:
            return CGPoint(x: targetFrame.minX + insetX, y: targetFrame.maxY - insetY)
        case .topRight:
            return CGPoint(x: targetFrame.maxX - insetX, y: targetFrame.maxY - insetY)
        case .bottomLeft:
            return CGPoint(x: targetFrame.minX + insetX, y: targetFrame.minY + insetY)
        case .bottomRight:
            return CGPoint(x: targetFrame.maxX - insetX, y: targetFrame.minY + insetY)
        }
    }
}
