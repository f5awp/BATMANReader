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
// header — SAME top-bar layout as Home (name row centre ≈ 255)
func anonHeader() {
  let orange = NSColor(red:0.894,green:0.545,blue:0.188,alpha:1)
  let av = NSRect(x:44, y: ay(210+90), width:92, height:90)
  orange.setFill(); NSBezierPath(roundedRect: av, xRadius:22, yRadius:22).fill()
  let dx = NSAttributedString(string:"DX", attributes:[.font:NSFont(name:"HelveticaNeue-Bold",size:40)!,.foregroundColor:NSColor.white])
  dx.draw(at: NSPoint(x: av.midX - dx.size().width/2, y: av.midY - dx.size().height/2))
  blackBar(x:150, topY:198, w:590, h:118); stamp("Dispatcher", x:152, centerTopY:255, size:62)
}
let letters = ["B","C","D","E","F","G","H","I","J","K"]
anonHeader()
// per-row name relabel (avatars are plain squares, no initials; grids/dates/buttons stay)
let (rows, barX, barW, sz): ([CGFloat], CGFloat, CGFloat, CGFloat) = {
  switch mode {
  case "ftsol": return ([1305,1551,1797,2043,2289], 112, 495, 40)          // Trade Solutions (Date Range)
  default:      return ([1284,1460,1636,1812,1988,2164], 112, 450, 38)      // ftecb — ECB queue (denser)
  }
}()
for (i,ry) in rows.enumerated() {
  let h = sz+22; blackBar(x:barX, topY:ry-h/2, w:barW, h:h)
  stamp("Dispatcher \(letters[i])", x:barX+8, centerTopY:ry, size:sz)
}
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using:.jpeg, properties:[.compressionFactor:0.92])!.write(to: URL(fileURLWithPath: outP))
print("wrote", outP)
