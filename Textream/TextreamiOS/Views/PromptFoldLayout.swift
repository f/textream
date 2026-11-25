import SwiftUI

/// How the prompt session divides its screen around a folding display's hinge.
///
/// On iPhone Duo the inner display reports a `.division` reserved region while
/// it is partially folded. A fold that runs across the screen is the tabletop
/// posture: the half that stands upright holds the stage (camera and prompt),
/// and the half that rests on the table holds the controls. A fold that runs
/// down the screen is the book posture: the stage takes the leading half and
/// the controls take the trailing half. A flat or closed display reports no
/// active division, so the stage fills the screen and the controls float over
/// it as on every other iPhone.
struct PromptFoldLayout: Equatable {
    enum Posture: Equatable {
        /// The fold runs across the screen; the stage sits above it.
        case tabletop
        /// The fold runs down the screen; the stage sits on its leading side.
        case book
    }

    /// A pane shorter or narrower than this cannot hold the stage or the
    /// controls, so the session keeps its unsplit layout instead.
    static let minimumPaneLength: CGFloat = 160

    let posture: Posture
    /// The stage's region, in the container's coordinate space.
    let stage: CGRect
    /// The controls' region, in the container's coordinate space.
    let controls: CGRect

    /// Splits a container around a fold. `fold` is the division region's frame,
    /// margins included, in the container's coordinate space.
    init?(fold: CGRect?, containerSize: CGSize) {
        guard let fold else { return nil }
        let bounds = CGRect(origin: .zero, size: containerSize)
        let division = fold.intersection(bounds)
        guard !division.isNull, !division.isEmpty else { return nil }

        let stage: CGRect
        let controls: CGRect
        let posture: Posture
        if division.width >= division.height {
            posture = .tabletop
            stage = CGRect(
                x: 0,
                y: 0,
                width: containerSize.width,
                height: division.minY
            )
            controls = CGRect(
                x: 0,
                y: division.maxY,
                width: containerSize.width,
                height: containerSize.height - division.maxY
            )
        } else {
            posture = .book
            stage = CGRect(
                x: 0,
                y: 0,
                width: division.minX,
                height: containerSize.height
            )
            controls = CGRect(
                x: division.maxX,
                y: 0,
                width: containerSize.width - division.maxX,
                height: containerSize.height
            )
        }

        guard min(stage.width, stage.height) >= Self.minimumPaneLength,
              min(controls.width, controls.height) >= Self.minimumPaneLength else {
            return nil
        }
        self.posture = posture
        self.stage = stage
        self.controls = controls
    }

    /// The active fold of the display that holds `geometry`, or `nil` where the
    /// display is flat, closed, or cannot fold.
    static func current(in geometry: GeometryProxy) -> PromptFoldLayout? {
        guard #available(iOS 27.1, *) else { return nil }
        // Reserved regions have no change notification. Read them in the body
        // on every layout pass and never cache them.
        let fold = geometry.reservedRegions(kind: .division)
            .first(where: \.isActive)?
            .frame
        return PromptFoldLayout(fold: fold, containerSize: geometry.size)
    }
}
