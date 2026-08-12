import UIKit

@MainActor
protocol IdleTimerControlling: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

extension UIApplication: IdleTimerControlling {}

/// Keeps the display awake while one or more fullscreen prompter sessions are open.
///
/// The coordinator remembers the process-wide value that existed before Textream's
/// first session opened and restores it only after the final session closes. This
/// makes repeated SwiftUI appearances and overlapping scenes safe.
@MainActor
final class PromptSessionIdleTimerCoordinator {
    static let shared = PromptSessionIdleTimerCoordinator()

    private let controller: any IdleTimerControlling
    private var previousValue: Bool?
    private var activeOwners: Set<UUID> = []

    init(controller: any IdleTimerControlling = UIApplication.shared) {
        self.controller = controller
    }

    func update(isActive: Bool, owner: UUID) {
        isActive ? acquire(owner: owner) : release(owner: owner)
    }

    func acquire(owner: UUID) {
        guard activeOwners.insert(owner).inserted else { return }
        if activeOwners.count == 1 {
            previousValue = controller.isIdleTimerDisabled
            if !controller.isIdleTimerDisabled {
                controller.isIdleTimerDisabled = true
            }
        }
    }

    func release(owner: UUID) {
        guard activeOwners.remove(owner) != nil,
              activeOwners.isEmpty,
              let previousValue else { return }
        self.previousValue = nil
        if controller.isIdleTimerDisabled != previousValue {
            controller.isIdleTimerDisabled = previousValue
        }
    }
}
