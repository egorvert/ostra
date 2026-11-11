import AppKit
import OstraCore
import SwiftUI

extension AppModel {
    var zoom: CGFloat { store.camera.zoom }

    /// The tallest the chat pane gets in the current window.
    var chatPaneHeight: CGFloat {
        min(640, max(300, viewSize.height * 0.62))
    }

    /// The band at the top of the window that the dock never covers, so the
    /// selected agent's card stays in view above its conversation.
    var topBand: CGFloat { 206 }

    /// The tallest the dock (pane, request bar, and chat box) gets.
    var dockMaxHeight: CGFloat {
        max(260, viewSize.height - topBand - Theme.hudMargin)
    }

    /// The dock grew or shrank: keep the selected card clear of it.
    func dockFrameChanged() {
        guard let agent = store.selectedAgent, draggingAgentID == nil else { return }
        reveal(agent, animated: true)
    }

    func screenPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: (world.x - store.camera.x) * zoom + viewSize.width / 2,
            y: (world.y - store.camera.y) * zoom + viewSize.height / 2
        )
    }

    func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(
            x: (screen.x - viewSize.width / 2) / zoom + store.camera.x,
            y: (screen.y - viewSize.height / 2) / zoom + store.camera.y
        )
    }

    /// The part of the window that no HUD panel covers.
    var freeRegion: CGRect {
        var rect = CGRect(origin: .zero, size: viewSize)
        let top: CGFloat = 50
        // Measure the dock where possible; estimate it before its first layout.
        var bottom: CGFloat = 92
        if let dock = hudRegions.frame("chat"), dock.height > 0 {
            bottom = viewSize.height - dock.minY + 14
        } else if chatOpen, store.selectedAgentID != nil {
            bottom += chatPaneHeight + 10
        }
        var left: CGFloat = 28
        if workspaceOpen {
            left = workspaceWidth + Theme.hudMargin + 24
        }
        rect.origin.x += left
        rect.size.width -= left + 28
        rect.origin.y += top
        rect.size.height -= top + bottom
        if rect.width < 120 || rect.height < 80 {
            return CGRect(origin: .zero, size: viewSize).insetBy(dx: 20, dy: 20)
        }
        return rect
    }

    func setCamera(_ camera: CameraState, animated: Bool) {
        Motion.perform(Motion.camera, animated: animated && !reduceMotion) {
            store.camera = camera
        }
    }

    /// Moves the camera only as far as it takes to bring the agent's card into the free region.
    func reveal(_ agent: AgentModel, animated: Bool) {
        guard viewSize.width > 0 else { return }
        let card = CanvasLayout.footprintRect(at: agent.position)
        let origin = screenPoint(card.origin)
        let frame = CGRect(x: origin.x, y: origin.y, width: card.width * zoom, height: card.height * zoom)
        let free = freeRegion.insetBy(dx: 16, dy: 12)
        guard !free.contains(frame) else { return }

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if frame.width > free.width {
            dx = free.midX - frame.midX
        } else if frame.minX < free.minX {
            dx = free.minX - frame.minX
        } else if frame.maxX > free.maxX {
            dx = free.maxX - frame.maxX
        }
        if frame.height > free.height {
            dy = free.midY - frame.midY
        } else if frame.minY < free.minY {
            dy = free.minY - frame.minY
        } else if frame.maxY > free.maxY {
            dy = free.maxY - frame.maxY
        }

        var camera = store.camera
        camera.x -= dx / zoom
        camera.y -= dy / zoom
        setCamera(camera, animated: animated)
    }

    /// Centers the camera on the agent's card.
    func center(on agent: AgentModel, animated: Bool) {
        let free = freeRegion
        var camera = store.camera
        camera.x = agent.position.x - (free.midX - viewSize.width / 2) / zoom
        camera.y = agent.position.y - (free.midY - viewSize.height / 2) / zoom
        setCamera(camera, animated: animated)
    }

    /// Frames a world rectangle in the free region.
    func frame(_ bounds: CGRect, animated: Bool, maxZoom: CGFloat = 1) {
        guard viewSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        let free = freeRegion.insetBy(dx: 30, dy: 24)
        let fit = min(free.width / bounds.width, free.height / bounds.height, maxZoom)
        let zoom = min(max(fit, CameraState.zoomRange.lowerBound), CameraState.zoomRange.upperBound)
        var camera = store.camera
        camera.zoom = zoom
        camera.x = bounds.midX - (free.midX - viewSize.width / 2) / zoom
        camera.y = bounds.midY - (free.midY - viewSize.height / 2) / zoom
        setCamera(camera, animated: animated)
    }

    func zoomToFit(animated: Bool) {
        guard let bounds = store.contentBounds else {
            setCamera(CameraState(), animated: animated)
            return
        }
        frame(bounds, animated: animated)
    }

    /// Zooms while keeping the world point under `screen` in place.
    func zoom(by factor: CGFloat, around screen: CGPoint, animated: Bool = false) {
        let current = store.camera.zoom
        let next = min(max(current * factor, CameraState.zoomRange.lowerBound), CameraState.zoomRange.upperBound)
        guard abs(next - current) > 0.0001 else { return }
        let anchor = worldPoint(screen)
        var camera = store.camera
        camera.zoom = next
        camera.x = anchor.x - (screen.x - viewSize.width / 2) / next
        camera.y = anchor.y - (screen.y - viewSize.height / 2) / next
        setCamera(camera, animated: animated)
    }

    func zoomStep(_ factor: CGFloat) {
        let free = freeRegion
        zoom(by: factor, around: CGPoint(x: free.midX, y: free.midY), animated: true)
    }

    /// Pans by a distance in screen points.
    func pan(by delta: CGSize) {
        var camera = store.camera
        camera.x -= delta.width / zoom
        camera.y -= delta.height / zoom
        store.camera = camera
    }

    /// Handles trackpad scrolls and pinches that land on the canvas.
    /// Returns false when the gesture belongs to a HUD panel.
    func handleCanvasGesture(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView,
              window === NSApp.mainWindow || window === NSApp.keyWindow else { return false }
        switch overlay {
        case .settings, .shortcuts: return false
        default: break
        }
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        guard CGRect(origin: .zero, size: viewSize).contains(point), !hudRegions.contains(point) else {
            return false
        }

        switch event.type {
        case .magnify:
            zoom(by: 1 + event.magnification, around: point)
            return true
        case .scrollWheel:
            if event.modifierFlags.contains(.command) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                zoom(by: exp(delta * 0.008), around: point)
                return true
            }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
            return true
        default:
            return false
        }
    }
}
