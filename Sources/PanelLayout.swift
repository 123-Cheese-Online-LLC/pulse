import Foundation
import CoreGraphics

/// Screen-space coordinates: positive Y is up. Keep the entire panel below the menu bar.
func panelFrame(anchor: CGRect, visibleFrame: CGRect) -> CGRect {
    let safe = visibleFrame.insetBy(dx: 8, dy: 8)
    let width = min(340, safe.width)
    let top = min(anchor.minY - 8, safe.maxY)
    let height = min(560, max(0, top - safe.minY))
    let x = min(max(anchor.maxX - width, safe.minX), safe.maxX - width)
    return CGRect(x: x, y: top - height, width: width, height: height)
}
