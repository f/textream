//
//  AttachedOverlayTypes.swift
//  Textream
//
//  Created by OpenAI Codex on 21.03.2026.
//

import Foundation

enum AttachedAnchorCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}
