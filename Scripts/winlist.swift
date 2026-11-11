// Prints the on-screen windows whose owner name contains the first argument,
// one per line: "<window id> <owner> <width> <height>". Scripts/snapshot.sh
// uses the ID to capture one window with screencapture.
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let filter = CommandLine.arguments.dropFirst().first

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    if let filter, !owner.contains(filter) { continue }
    guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(id, owner, bounds["Width"] ?? 0, bounds["Height"] ?? 0)
}
