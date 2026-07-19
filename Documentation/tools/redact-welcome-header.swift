import AppKit

// Redacts the top-left header (avatar + own name) to match the "Dispatcher" onboarding convention.
// Usage: swift redact.swift <in.png> <out.jpg>
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("need in out") }
let src = NSBitmapImageRep(data: NSImage(contentsOfFile: args[1])!.tiffRepresentation!)!
let W = src.pixelsWide, H = src.pixelsHigh

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let ctx = NSGraphicsContext.current!.cgContext

// 1) original
src.draw(in: NSRect(x: 0, y: 0, width: W, height: H))

// helper: AppKit y (bottom-left origin) from image-top y
func ay(_ topY: Int, _ h: Int) -> Int { H - (topY + h) }

// 2) black out the name text region (header bg is pure black, so this is invisible except erasing the name)
NSColor.black.setFill()
NSBezierPath(rect: NSRect(x: 150, y: ay(198, 118), width: 590, height: 118)).fill()

// 3) repaint avatar tile orange + "DX"
let orange = NSColor(red: 0.894, green: 0.545, blue: 0.188, alpha: 1)
let avatar = NSRect(x: 44, y: ay(210, 90), width: 92, height: 90)
orange.setFill()
NSBezierPath(roundedRect: avatar, xRadius: 22, yRadius: 22).fill()
let dxAttr: [NSAttributedString.Key: Any] = [
  .font: NSFont(name: "HelveticaNeue-Bold", size: 40)!, .foregroundColor: NSColor.white]
let dx = NSAttributedString(string: "DX", attributes: dxAttr)
let dxSize = dx.size()
dx.draw(at: NSPoint(x: avatar.midX - dxSize.width/2, y: avatar.midY - dxSize.height/2))

// 4) "Dispatcher" name, left-aligned where "Lee, Ervin" began
let nameAttr: [NSAttributedString.Key: Any] = [
  .font: NSFont(name: "HelveticaNeue-Bold", size: 62)!, .foregroundColor: NSColor.white]
let name = NSAttributedString(string: "Dispatcher", attributes: nameAttr)
let nSize = name.size()
let rowMidTopY = 255   // image-top y of the header row centre
name.draw(at: NSPoint(x: 152, y: H - rowMidTopY - Int(nSize.height/2)))

NSGraphicsContext.restoreGraphicsState()
let jpg = out.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
try! jpg.write(to: URL(fileURLWithPath: args[2]))
print("wrote", args[2])
