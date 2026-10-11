// Draws Relay's app icon (1024×1024) with CoreGraphics: the in-app logo —
// a checklist on a blue tile. `mac` leaves the macOS margin and shadow
// (824 px tile); `ios` fills the square (iOS masks the corners itself; the app icons are flattened to no alpha for App Store Connect).
//   swift tool/render_icon.swift mac design/icon/relay-mac-1024.png
import AppKit

let args = CommandLine.arguments
let mac = args[1] == "mac"
let out = args[2]
let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = mac ? 185 : 0
let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

if mac {
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
  ctx.addPath(path)
  ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.39, blue: 0.85, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [
  CGColor(srgbRed: 0.16, green: 0.53, blue: 0.98, alpha: 1),
  CGColor(srgbRed: 0.02, green: 0.33, blue: 0.78, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
// A soft top highlight.
let gloss = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.midY), options: [])
ctx.restoreGState()

// The checklist: two ticks and two lines, then a third line (in progress).
let u = tile.width / 824
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.maxY - y * u) }
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(58 * u)
for y in [270.0, 430.0] {
  ctx.move(to: p(190, y))
  ctx.addLine(to: p(245, y + 52))
  ctx.addLine(to: p(345, y - 52))
}
ctx.strokePath()
ctx.setLineWidth(62 * u)
for (y, end) in [(270.0, 640.0), (430.0, 640.0)] {
  ctx.move(to: p(430, y))
  ctx.addLine(to: p(end, y))
}
ctx.strokePath()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
ctx.move(to: p(190, 590))
ctx.addLine(to: p(640, 590))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
