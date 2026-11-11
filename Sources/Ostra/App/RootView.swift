import OstraCore
import SwiftUI

/// The window's content: the canvas with the HUD floating over it.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var framedOnce = false

    var body: some View {
        ZStack {
            CanvasView()
            HUDLayer()
        }
        .ignoresSafeArea()
        .preferredColorScheme(app.settings.data.appearance.colorScheme)
        .onChange(of: reduceMotion, initial: true) { _, value in
            app.reduceMotion = value
            Motion.reduced = value
        }
        // Files and images dropped anywhere in the window join the draft.
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: dropTargeted) { providers in
            app.handleDrop(providers)
        }
        .onAppear {
            // Start in command mode: AppKit would otherwise hand the keyboard
            // to the first text view it finds.
            DispatchQueue.main.async { app.focus.blur() }
        }
        .onChange(of: app.store.hasLoaded, initial: true) { _, _ in frameContentOnce() }
        .onChange(of: app.viewSize) { _, _ in frameContentOnce() }
    }

    private var dropTargeted: Binding<Bool> {
        Binding(get: { app.isDropTargeted }, set: { app.isDropTargeted = $0 })
    }

    /// On a fresh install the camera has no saved position, so show everything.
    private func frameContentOnce() {
        guard !framedOnce, app.store.hasLoaded, app.viewSize.width > 0 else { return }
        framedOnce = true
        guard app.store.camera == CameraState() else { return }
        // Wait a beat, so the window and the dock have their final sizes.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            if app.store.camera == CameraState() {
                app.zoomToFit(animated: false)
            }
        }
    }
}
