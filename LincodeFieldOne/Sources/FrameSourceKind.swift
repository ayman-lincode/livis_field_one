import Foundation

/// Where live video comes from.
enum FrameSourceKind: String, CaseIterable, Identifiable, Codable {
    /// ENDLESSRIVER FIELD ONE over Wi-Fi, through the client SDK.
    case fieldOne
    /// This iPhone's own camera. Used for bench testing a model when the
    /// FIELD ONE hardware is not to hand.
    case deviceCamera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fieldOne: "FIELD ONE"
        case .deviceCamera: "This iPhone"
        }
    }

    var subtitle: String {
        switch self {
        case .fieldOne: "ENDLESSRIVER wearable camera over Wi-Fi"
        case .deviceCamera: "Built-in camera, for bench testing a model"
        }
    }

    var systemImage: String {
        switch self {
        case .fieldOne: "wave.3.right.circle"
        case .deviceCamera: "iphone.gen3.camera"
        }
    }
}
