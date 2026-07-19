import AppKit
let a = CommandLine.arguments
let src = NSBitmapImageRep(data: NSImage(contentsOfFile:a[1])!.tiffRepresentation!)!
let W = src.pixelsWide, H = src.pixelsHigh
let out = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,
  hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
src.draw(in: NSRect(x:0,y:0,width:W,height:H))
func ay(_ t: CGFloat) -> CGFloat { CGFloat(H) - t }
func bar(_ x: CGFloat,_ topY: CGFloat,_ w: CGFloat,_ h: CGFloat,_ col: NSColor = .black) {
  col.setFill(); NSBezierPath(rect: NSRect(x:x,y:ay(topY+h),width:w,height:h)).fill()
}
func stamp(_ s: String,_ x: CGFloat,_ cY: CGFloat,_ size: CGFloat,_ col: NSColor = .white) {
  let st = NSAttributedString(string:s, attributes:[.font:NSFont(name:"HelveticaNeue-Bold",size:size)!,.foregroundColor:col])
  st.draw(at: NSPoint(x:x, y: ay(cY + st.size().height/2)))
}
let cardBG = NSColor(red:0.110,green:0.110,blue:0.118,alpha:1)  // expanded-card fill (so value bars vanish into it)
let linkBlue = NSColor(red:0.19,green:0.44,blue:0.85,alpha:1)
let letters = ["B","C","D","E","F"]
// header — Home top bar
let orange = NSColor(red:0.894,green:0.545,blue:0.188,alpha:1)
let av = NSRect(x:44,y:ay(210+90),width:92,height:90)
orange.setFill(); NSBezierPath(roundedRect:av,xRadius:22,yRadius:22).fill()
let dx = NSAttributedString(string:"DX",attributes:[.font:NSFont(name:"HelveticaNeue-Bold",size:40)!,.foregroundColor:NSColor.white])
dx.draw(at: NSPoint(x:av.midX-dx.size().width/2,y:av.midY-dx.size().height/2))
bar(150,198,590,118); stamp("Dispatcher",152,255,62)
// rows: slate avatar + relabelled name (keep #seniority)
let rows: [CGFloat] = [918,1078,1290,2220,2415]
for (i,ry) in rows.enumerated() {
  NSColor(red:0.49,green:0.49,blue:0.627,alpha:1).setFill()
  NSBezierPath(roundedRect: NSRect(x:22,y:ay(ry+44),width:126,height:88),xRadius:20,yRadius:20).fill()
  bar(145,ry-44,515,88); stamp("Dispatcher \(letters[i])",152,ry,40)
}
// expanded card PII → fake placeholders (bars use card fill so they blend)
bar(395,1430-32,250,64,cardBG); stamp("451882",400,1430,40)
bar(412,1588-32,470,64,cardBG); stamp("(555) 010-0100",420,1588,40,linkBlue)
bar(412,1665-32,590,64,cardBG); stamp("dispatcher@aa.com",420,1665,40,linkBlue)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using:.jpeg,properties:[.compressionFactor:0.92])!.write(to: URL(fileURLWithPath:a[2]))
print("wrote", a[2])
