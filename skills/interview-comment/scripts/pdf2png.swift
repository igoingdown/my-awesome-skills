import Foundation
import PDFKit
import AppKit

let args = CommandLine.arguments
let pdfURL = URL(fileURLWithPath: args[1])
let outPath = args[2]
let scale: CGFloat = 3.0

guard let doc = PDFDocument(url: pdfURL) else { print("cannot open pdf"); exit(1) }

var pageImages: [NSImage] = []
var totalHeight: CGFloat = 0
var maxWidth: CGFloat = 0

for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let bounds = page.bounds(for: .mediaBox)
    let w = bounds.width * scale
    let h = bounds.height * scale
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    ctx.restoreGState()
    img.unlockFocus()
    pageImages.append(img)
    totalHeight += h
    maxWidth = max(maxWidth, w)
}

let longImg = NSImage(size: NSSize(width: maxWidth, height: totalHeight))
longImg.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: maxWidth, height: totalHeight).fill()
var y = totalHeight
for img in pageImages {
    y -= img.size.height
    img.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
}
longImg.unlockFocus()

guard let tiff = longImg.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { print("encode fail"); exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("done \(Int(maxWidth))x\(Int(totalHeight))")
