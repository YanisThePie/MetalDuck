//
//  AppleVSRTargetMode.swift
//  MetalDuck
//

import Foundation

enum AppleVSRTargetMode: String, CaseIterable {
    case automatic = "Auto"
    case p1440 = "2560×1440"
    case p2160 = "3840×2160"

    var fixedResolution: CGSize? {
        switch self {
        case .automatic:
            return nil
        case .p1440:
            return CGSize(width: 2560, height: 1440)
        case .p2160:
            return CGSize(width: 3840, height: 2160)
        }
    }
}
