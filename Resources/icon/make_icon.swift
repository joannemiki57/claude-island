// Renders the app icon (1024x1024 PNG): an island hanging from the top of the
// icon with three status rows.
//
//   swift make_icon.swift out.png [style]
//
// Styles: clay (default), paper, ivory, night.
import AppKit

struct Palette {
    var background: [UInt32]          // top, middle, bottom
    var glow: (UInt32, CGFloat)       // warm light under the island
    var island: UInt32
    var islandRim: (UInt32, CGFloat)
    var islandShadow: CGFloat
    var bar: UInt32
    var barAlphas: [CGFloat]
    var amber: UInt32
    var spinner: UInt32
    var blue: UInt32
    var sheen: CGFloat
    var border: (UInt32, CGFloat)
}

let palettes: [String: Palette] = [
    // Warm terracotta body with a black island.
    "clay": Palette(background: [0xF0906A, 0xE4714A, 0xD65C36], glow: (0xFFF4E6, 0.22),
                    island: 0x1A1714, islandRim: (0xFFFFFF, 0.08), islandShadow: 0.45,
                    bar: 0xF5EFE4, barAlphas: [0.96, 0.70, 0.46],
                    amber: 0xFFBD40, spinner: 0xE8875F, blue: 0x5AA5FF,
                    sheen: 0.12, border: (0xFFFFFF, 0.10)),
    // Ivory paper body with a warm black island.
    "paper": Palette(background: [0xFBF8F2, 0xF2ECE1, 0xE6DDCD], glow: (0xD97757, 0.22),
                     island: 0x1F1D1A, islandRim: (0x000000, 0.10), islandShadow: 0.30,
                     bar: 0xF5EFE4, barAlphas: [0.96, 0.70, 0.46],
                     amber: 0xFFBD40, spinner: 0xE07B57, blue: 0x5AA5FF,
                     sheen: 0.0, border: (0x000000, 0.06)),
    // Terracotta body with an ivory island.
    "ivory": Palette(background: [0xF0906A, 0xE4714A, 0xD65C36], glow: (0xFFF4E6, 0.0),
                     island: 0xF7F2E8, islandRim: (0xFFFFFF, 0.25), islandShadow: 0.28,
                     bar: 0x3B342C, barAlphas: [0.88, 0.55, 0.32],
                     amber: 0xF2A626, spinner: 0xD06B45, blue: 0x3F8CF0,
                     sheen: 0.10, border: (0xFFFFFF, 0.10)),
    // The original dark version.
    "night": Palette(background: [0x3A3F5C, 0x1B1E2C, 0x0F1118], glow: (0xE07B57, 0.34),
                     island: 0x000000, islandRim: (0xFFFFFF, 0.10), islandShadow: 0.55,
                     bar: 0xFFFFFF, barAlphas: [0.95, 0.72, 0.50],
                     amber: 0xFFBD40, spinner: 0xE07B57, blue: 0x4D9EFF,
                     sheen: 0.07, border: (0xFFFFFF, 0.08)),
]

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon_1024.png"
let styleName = args.count > 2 ? args[2] : "clay"
guard let p = palettes[styleName] else {
    print("unknown style \(styleName); use one of \(palettes.keys.sorted().joined(separator: ", "))")
    exit(1)
}

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

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
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: rgb(0x000000, 0.25))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(p.background[1]))
ctx.fillPath()
ctx.restoreGState()

// Background gradient.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: p.background.map { rgb($0) } as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Soft light under the island.
if p.glow.1 > 0 {
    let glow = CGGradient(colorsSpace: space, colors: [rgb(p.glow.0, p.glow.1), rgb(p.glow.0, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 780), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 780), endRadius: 400, options: [])
}

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
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, p.islandShadow))
ctx.addPath(islandPath)
ctx.setFillColor(rgb(p.island))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(islandPath)
ctx.setStrokeColor(rgb(p.islandRim.0, p.islandRim.1))
ctx.setLineWidth(3)
ctx.strokePath()

// Rows: amber (needs you), spinner (running), blue (unread).
let rowX: CGFloat = island.minX + 104
let barX: CGFloat = island.minX + 186
let rowY: [CGFloat] = [262, 402, 542]
let barW: [CGFloat] = [330, 270, 210]

ctx.setFillColor(rgb(p.amber))
ctx.fillEllipse(in: CGRect(x: rowX - 31, y: rowY[0] - 31, width: 62, height: 62))
ctx.setStrokeColor(rgb(p.amber, 0.45))
ctx.setLineWidth(9)
ctx.strokeEllipse(in: CGRect(x: rowX - 52, y: rowY[0] - 52, width: 104, height: 104))

ctx.setStrokeColor(rgb(p.spinner))
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: rowX, y: rowY[1]), radius: 36,
           startAngle: -CGFloat.pi * 0.35, endAngle: CGFloat.pi * 1.15, clockwise: false)
ctx.strokePath()

ctx.setFillColor(rgb(p.blue))
ctx.fillEllipse(in: CGRect(x: rowX - 27, y: rowY[2] - 27, width: 54, height: 54))

for i in 0..<3 {
    let bar = CGRect(x: barX, y: rowY[i] - 19, width: barW[i], height: 38)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 19, cornerHeight: 19, transform: nil))
    ctx.setFillColor(rgb(p.bar, p.barAlphas[i]))
    ctx.fillPath()
}

// Subtle top sheen on the body.
if p.sheen > 0 {
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, p.sheen), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 500), options: [])
}
ctx.restoreGState()

// Inner border.
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(p.border.0, p.border.1))
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(styleName))")
