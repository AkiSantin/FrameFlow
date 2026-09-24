import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import FrameFlowCore

enum IconAssets {
    static func prepare(source: URL, root: URL) throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { throw HarnessError.pathExists(root.path) }
        let original = try Data(contentsOf: source)
        let signature = Data([137,80,78,71,13,10,26,10])
        guard original.prefix(8) == signature else { throw HarnessError.assertion("Expected PNG") }
        var clean = signature
        var originalIDAT = Data()
        var offset = 8
        let keep = Set(["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "pHYs"])
        while offset + 12 <= original.count {
            let size = original[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard size <= original.count - offset - 12,
                  let type = String(data: original[offset+4..<offset+8], encoding: .ascii) else {
                throw HarnessError.assertion("Invalid PNG chunk")
            }
            if keep.contains(type) { clean.append(original[offset..<offset+size+12]) }
            if type == "IDAT" { originalIDAT.append(original[offset+8..<offset+8+size]) }
            offset += size + 12
        }
        guard offset == original.count else { throw HarnessError.assertion("Trailing PNG data") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleaned = root.appendingPathComponent("AppIcon.png")
        try clean.write(to: cleaned, options: .withoutOverwriting)
        var cleanIDAT = Data()
        offset = 8
        while offset + 12 <= clean.count {
            let size = clean[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            if String(data: clean[offset+4..<offset+8], encoding: .ascii) == "IDAT" {
                cleanIDAT.append(clean[offset+8..<offset+8+size])
            }
            offset += size + 12
        }
        guard originalIDAT == cleanIDAT,
              let imageSource = CGImageSourceCreateWithData(clean as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw HarnessError.assertion("Icon pixels were not preserved")
        }
        let iconset = root.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
        for size in [16,32,128,256,512] {
            for scale in [1,2] {
                let pixels = size * scale
                let resized = try AspectRenderer.resized(image: image, width: pixels)
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try ImageWriter.write(image: resized, to: iconset.appendingPathComponent(name), format: .png, jpegQuality: 1)
            }
        }
        print("ICON_METADATA_REMOVED_ORIGINAL_IDAT_IDENTICAL")
    }
}

