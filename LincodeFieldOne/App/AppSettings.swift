import Foundation
import SwiftUI

/// Everything the operator can change, persisted between launches.
@MainActor
@Observable
final class AppSettings {
    var detection: DetectionSettings {
        didSet { persist(detection, as: "detectionSettings") }
    }

    /// Ask the SDK to show the iOS prompt to join the camera's own Wi-Fi.
    var joinWiFiAutomatically: Bool {
        didSet { defaults.set(joinWiFiAutomatically, forKey: "joinWiFiAutomatically") }
    }

    /// A known camera address, when discovery should be skipped.
    var preferredHost: String {
        didSet { defaults.set(preferredHost, forKey: "preferredHost") }
    }

    var preferredSource: FrameSourceKind {
        didSet { defaults.set(preferredSource.rawValue, forKey: "preferredSource") }
    }

    var burnInMetadata: Bool {
        didSet { defaults.set(burnInMetadata, forKey: "burnInMetadata") }
    }

    var showLabels: Bool {
        didSet { defaults.set(showLabels, forKey: "showLabels") }
    }

    var showConfidence: Bool {
        didSet { defaults.set(showConfidence, forKey: "showConfidence") }
    }

    var hapticOnCapture: Bool {
        didSet { defaults.set(hapticOnCapture, forKey: "hapticOnCapture") }
    }

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        detection = AppSettings.load(DetectionSettings.self, from: "detectionSettings")
            ?? DetectionSettings()
        joinWiFiAutomatically = defaults.bool(forKey: "joinWiFiAutomatically")
        preferredHost = defaults.string(forKey: "preferredHost") ?? ""
        preferredSource = FrameSourceKind(
            rawValue: defaults.string(forKey: "preferredSource") ?? ""
        ) ?? .fieldOne
        burnInMetadata = defaults.object(forKey: "burnInMetadata") as? Bool ?? true
        showLabels = defaults.object(forKey: "showLabels") as? Bool ?? true
        showConfidence = defaults.object(forKey: "showConfidence") as? Bool ?? true
        hapticOnCapture = defaults.object(forKey: "hapticOnCapture") as? Bool ?? true
    }

    private func persist<T: Encodable>(_ value: T, as key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
