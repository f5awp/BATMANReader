import AppKit
let a = CommandLine.arguments
let (inP, outP, mode) = (a[1], a[2], a[3])
let src = NSBitmapImageRep(data: NSImage(contentsOfFile: inP)!.tiffRepresentation!)!
let W = src.pixelsWide, H = src.pixelsHigh
let out = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,
  hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
src.draw(in: NSRect(x:0,y:0,width:W,height:H))
func ay(_ topY: CGFloat) -> CGFloat { CGFloat(H) - topY }
func blackBar(x: CGFloat, topY: CGFloat, w: CGFloat, h: CGFloat) {
  NSColor.black.setFill(); NSBezierPath(rect: NSRect(x:x, y: ay(topY+h), width:w, height:h)).fill()
}
func stamp(_ s: String, x: CGFloat, centerTopY: CGFloat, size: CGFloat) {
  let at: [NSAttributedString.Key:Any] = [.font: NSFont(name:"HelveticaNeue-Bold",size:size)!, .foregroundColor: NSColor.white]
  let str = NSAttributedString(string: s, attributes: at); let sz = str.size()
  str.draw(at: NSPoint(x:x, y: ay(centerTopY + sz.height/2)))
}
let letters = ["B","C","D","E","F","G","H","I","J","K"]

if mode == "dir" {
  // header — SAME top-bar layout as Home (name row centre ≈ image-top y 255)
  let orange = NSColor(red:0.894,green:0.545,blue:0.188,alpha:1)
  let av = NSRect(x:44, y: ay(210+90), width:92, height:90)
  orange.setFill(); NSBezierPath(roundedRect: av, xRadius:22, yRadius:22).fill()
  let dx = NSAttributedString(string:"DX", attributes:[.font:NSFont(name:"HelveticaNeue-Bold",size:40)!,.foregroundColor:NSColor.white])
  dx.draw(at: NSPoint(x: av.midX - dx.size().width/2, y: av.midY - dx.size().height/2))
  blackBar(x:150, topY:198, w:590, h:118); stamp("Dispatcher", x:152, centerTopY:255, size:62)
  // rows: cover initials-avatar (rounded square) + relabel name; keep #seniority
  let rows: [CGFloat] = [902,1100,1298,1496,1694,1892,2090,2288]
  for (i,ry) in rows.enumerated() {
    NSColor(red:0.49,green:0.49,blue:0.627,alpha:1).setFill()
    NSBezierPath(roundedRect: NSRect(x:22, y: ay(ry+44), width:126, height:88), xRadius:20, yRadius:20).fill()
    blackBar(x:145, topY:ry-44, w:560, h:88)
    stamp("Dispatcher \(letters[i])", x:152, centerTopY:ry, size:40)
  }
} else {
  // list: relabel each row's NAME line (dates/counts/buttons/avatars stay)
  let rows: [CGFloat] = [962,1208,1454,1700,1946,2192,2438,2684]
  for (i,ry) in rows.enumerated() {
    blackBar(x:112, topY:ry-40, w:495, h:70)
    stamp("Dispatcher \(letters[i])", x:120, centerTopY:ry, size:40)
  }
}
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using:.jpeg, properties:[.compressionFactor:0.92])!.write(to: URL(fileURLWithPath: outP))
print("wrote", outP)
