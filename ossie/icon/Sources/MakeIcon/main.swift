import CuaBotsCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The pairing screen's koala (cloud, star eyes, scalloped ears) on the
// palette's sky blue.
let side = 1024
let koala = AvatarConfig(color: .cloud, eyes: .star, ears: .scalloped)

@MainActor
func render() -> CGImage? {
    let view = ZStack {
        Color(hex: BotColor.sky.faceHex)
        KoalaAvatar(koala, mood: .idle, animated: false).padding(CGFloat(side) * 0.1)
    }
    .frame(width: CGFloat(side), height: CGFloat(side))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return renderer.cgImage
}

// App Store icons must be opaque, so flatten onto an RGB context without alpha.
func opaque(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")
guard let image = MainActor.assumeIsolated({ render() }).flatMap(opaque),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("could not write \(out.path)\n".utf8))
    exit(1)
}
print("wrote \(out.path) (\(image.width)x\(image.height), alpha: \(image.alphaInfo.rawValue))")
