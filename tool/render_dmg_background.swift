// Draws the DMG window's background (640×400 pt): Relay's soft blue, a
// curved arrow from the app (left) to Applications (right), and a caption.
// Icon centres must match tool/release/dmg_settings.py.
//   swift tool/render_dmg_background.swift 1 design/dmg/background.png
//   swift tool/render_dmg_background.swift 2 design/dmg/background@2x.png
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[1])!)
let out = CommandLine.arguments[2]
let (w, h): (CGFloat, CGFloat) = (640, 400)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
// Work in top-left coordinates like Finder's icon positions.
ctx.translateBy(x: 0, y: h)
ctx.scaleBy(x: 1, y: -1)

let bg = CGGradient(colorsSpace: cs, colors: [
  CGColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
  CGColor(srgbRed: 0.89, green: 0.93, blue: 0.99, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])

// Two faint rounded "wells" under the icons.
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
for x in [160.0, 480.0] {
  ctx.addPath(CGPath(roundedRect: CGRect(x: x - 78, y: 128, width: 156, height: 156), cornerWidth: 28, cornerHeight: 28, transform: nil))
}
ctx.fillPath()

// The arrow: a gentle arc from the app to Applications.
let blue = CGColor(srgbRed: 0.04, green: 0.39, blue: 0.85, alpha: 0.9)
ctx.setStrokeColor(blue)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 250, y: 214))
ctx.addQuadCurve(to: CGPoint(x: 384, y: 214), control: CGPoint(x: 317, y: 168))
ctx.strokePath()
ctx.setFillColor(blue)
ctx.move(to: CGPoint(x: 398, y: 222))
ctx.addLine(to: CGPoint(x: 374, y: 224))
ctx.addLine(to: CGPoint(x: 386, y: 202))
ctx.closePath()
ctx.fillPath()

// Caption (flip back for text).
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
  let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
  let str = NSAttributedString(string: s, attributes: attrs)
  let line = CTLineCreateWithAttributedString(str)
  let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
  ctx.saveGState()
  ctx.translateBy(x: (w - bounds.width) / 2, y: y)
  ctx.scaleBy(x: 1, y: -1)
  ctx.textPosition = .zero
  CTLineDraw(line, ctx)
  ctx.restoreGState()
}
text("Drag Relay to Applications", size: 22, weight: .semibold, color: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1), y: 82)
text("Your coding agents and your team, on one board", size: 13, weight: .regular, color: NSColor(srgbRed: 0.38, green: 0.42, blue: 0.48, alpha: 1), y: 340)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: w, height: h) // 72 dpi at 1×, 144 at 2×
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
