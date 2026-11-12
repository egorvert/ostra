// Prints the on-screen windows whose owner matches the first argument, one
// per line: "<window id> <owner> <width> <height>". The argument is a process
// ID or part of an owner name. Scripts/snapshot.sh passes the ID of the app
// it launched, so another running copy of Ostra never gets captured instead.
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let filter = CommandLine.arguments.dropFirst().first
let pid = filter.flatMap { Int32($0) }

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
    if let pid {
        if ownerPID != pid { continue }
    } else if let filter, !owner.contains(filter) {
        continue
    }
    guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(id, owner, bounds["Width"] ?? 0, bounds["Height"] ?? 0)
}
