import AppKit
import Foundation

// Composites a full-bleed source image onto a transparent 1024×1024 canvas at
// the standard macOS icon inset (~80%), so the Dock/Finder icon has the proper
// margin instead of filling the whole tile. Usage: swift make_icon.swift <src> <out>
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("make_icon: bad args or unreadable source\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
let inset: CGFloat = 0.82
let art = canvas * inset
let origin = (canvas - art) / 2

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
src.draw(in: NSRect(x: origin, y: origin, width: art, height: art),
         from: .zero, operation: .sourceOver, fraction: 1.0)
out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make_icon: encode failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
