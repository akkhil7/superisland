import Foundation
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's standard updater. Owned by
/// AppDelegate, injected into the menu-bar UI so the "Check for Updates…" item
/// can drive it and reflect availability.
@MainActor
final class SoftwareUpdater: ObservableObject {
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
