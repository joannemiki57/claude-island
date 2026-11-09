// Renders the app icon (1024x1024 PNG): an island hanging from the top of the
// icon with three status rows. Run: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Flip so y grows downward, which is easier to reason about.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824pt body centered in 1024, corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x1A1D2B))
ctx.fillPath()
ctx.restoreGState()

// Background gradient.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(0x3A3F5C), rgb(0x1B1E2C), rgb(0x0F1118)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Soft warm glow behind the island.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0xE07B57, 0.34), rgb(0xE07B57, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 760), endRadius: 400, options: [])

// The island: hangs from the top edge, rounded at the bottom.
let island = CGRect(x: 512 - 316, y: 60, width: 632, height: 600)
let r: CGFloat = 110
let islandPath = CGMutablePath()
islandPath.move(to: CGPoint(x: island.minX, y: island.minY))
islandPath.addLine(to: CGPoint(x: island.maxX, y: island.minY))
islandPath.addLine(to: CGPoint(x: island.maxX, y: island.maxY - r))
islandPath.addQuadCurve(to: CGPoint(x: island.maxX - r, y: island.maxY), control: CGPoint(x: island.maxX, y: island.maxY))
islandPath.addLine(to: CGPoint(x: island.minX + r, y: island.maxY))
islandPath.addQuadCurve(to: CGPoint(x: island.minX, y: island.maxY - r), control: CGPoint(x: island.minX, y: island.maxY))
islandPath.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.55))
ctx.addPath(islandPath)
ctx.setFillColor(rgb(0x000000))
ctx.fillPath()
ctx.restoreGState()
// Hairline rim light along the bottom of the island.
ctx.addPath(islandPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

// Rows: amber (needs you), orange spinner (running), blue (unread).
let rowX: CGFloat = island.minX + 104
let barX: CGFloat = island.minX + 186
let rows: [(y: CGFloat, bar: CGFloat, alpha: CGFloat)] = [(262, 330, 0.95), (402, 270, 0.72), (542, 210, 0.50)]

// 1. Amber dot with a halo ring.
ctx.setFillColor(rgb(0xFFBD40))
ctx.fillEllipse(in: CGRect(x: rowX - 31, y: rows[0].y - 31, width: 62, height: 62))
ctx.setStrokeColor(rgb(0xFFBD40, 0.45))
ctx.setLineWidth(9)
ctx.strokeEllipse(in: CGRect(x: rowX - 52, y: rows[0].y - 52, width: 104, height: 104))

// 2. Orange spinner arc.
ctx.setStrokeColor(rgb(0xE07B57))
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: rowX, y: rows[1].y), radius: 36,
           startAngle: -CGFloat.pi * 0.35, endAngle: CGFloat.pi * 1.15, clockwise: false)
ctx.strokePath()

// 3. Blue dot.
ctx.setFillColor(rgb(0x4D9EFF))
ctx.fillEllipse(in: CGRect(x: rowX - 27, y: rows[2].y - 27, width: 54, height: 54))

// Title bars.
for row in rows {
    let bar = CGRect(x: barX, y: row.y - 19, width: row.bar, height: 38)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 19, cornerHeight: 19, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, row.alpha))
    ctx.fillPath()
}

// Subtle top sheen on the body.
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 500), options: [])
ctx.restoreGState()

// Inner border.
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
