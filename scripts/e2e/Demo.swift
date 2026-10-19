import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Records the README demo from the real views and real captions: tucked strip →
/// spring open → captions playing → spring closed. Run with E2E_DEMO=1.
extension E2E {
    @MainActor static func demo(_ notch: NotchController, to url: URL) async throws {
        // Room for the open player plus the spring's overshoot.
        let canvas = CGSize(width: 760, height: ((notch.geometry.capHeight + notch.detailHeight) * 1.08 + 24).rounded())
        let stage = DemoProgress()
        let hosting = NSHostingView(rootView: DemoNotch(notch: notch, stage: stage))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        var frames: [(CGImage, Double)] = []
        func capture(_ progress: CGFloat, hold: Double) async {
            // Offscreen captures drop some symbols (e.g. ⟳30) once a notch that grew
            // into place reaches exactly 100%, though the screen shows them.
            // 99.5% looks identical and captures fully; the GIF loses only the
            // spring's slight overshoot.
            let progress = min(progress, 0.995)
            stage.progress = progress
            let size = DemoNotch.size(notch, progress)
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 60_000_000)
            if let image = compose(grab(hosting), size: size, canvas: canvas, menuBar: notch.geometry.capHeight) {
                frames.append((image, hold))
            }
        }
        // Real time passes while holding, so real captions advance on their own.
        func hold(_ progress: CGFloat, seconds: Double) async {
            let step = 0.25
            for _ in 0..<Int(seconds / step) {
                await capture(progress, hold: step)
                try? await Task.sleep(nanoseconds: UInt64(step * 1e9))
            }
        }
        await hold(0, seconds: 3.5)
        for value in spring(duration: 0.5, damping: 0.8, from: 0, to: 1) { await capture(value, hold: 1.0 / 30) }
        await hold(0.995, seconds: 6)
        for value in spring(duration: 0.45, damping: 1, from: 1, to: 0) { await capture(value, hold: 1.0 / 30) }
        await hold(0, seconds: 2.5)

        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw failure("Can't write \(url.path)") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw failure("GIF encoding failed") }
    }

    /// The app's own spring (NotchFrameAnimator), sampled at 30 fps.
    static func spring(duration: Double, damping: Double, from: Double, to goal: Double) -> [CGFloat] {
        let omega = 2 * Double.pi / duration
        var x = from, v = 0.0, values: [CGFloat] = []
        for _ in 0..<Int(duration * 30 * 1.6) {
            for _ in 0..<16 {
                let h = 1.0 / 480
                v += (-omega * omega * (x - goal) - 2 * damping * omega * v) * h
                x += v * h
            }
            values.append(CGFloat(x))
        }
        return values
    }

    @MainActor static func grab(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Wallpaper + menu bar + the notch hanging from the top center, at 1x so
    /// the GIF stays small enough for a README.
    static func compose(_ notch: CGImage?, size: CGSize, canvas: CGSize, menuBar: CGFloat) -> CGImage? {
        guard let notch, let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let colors = [CGColor(srgbRed: 0.16, green: 0.20, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.45, green: 0.30, blue: 0.48, alpha: 1),
                      CGColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.fill(CGRect(x: 0, y: canvas.height - menuBar, width: canvas.width, height: menuBar))
        context.draw(notch, in: CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height,
                                       width: size.width, height: size.height))
        return context.makeImage()
    }
}

@MainActor
private final class DemoProgress: ObservableObject {
    @Published var progress: CGFloat = 0
}

/// The real notch view at a given expansion, framed exactly to its size.
private struct DemoNotch: View {
    let notch: NotchController
    @ObservedObject var stage: DemoProgress

    /// Overshoot (progress > 1) grows the frame a little, like the real window.
    @MainActor static func size(_ notch: NotchController, _ progress: CGFloat) -> CGSize {
        // Whole points keep edges crisp; rounding down keeps 99.5% below the
        // full height, so it never reads as 100%.
        CGSize(width: (notch.tuckedWidth + (notch.expandedWidth - notch.tuckedWidth) * progress + 2 * NotchController.shoulder).rounded(.down),
               height: max(1, notch.tuckedHeight + (notch.geometry.capHeight + notch.detailHeight - notch.tuckedHeight) * progress).rounded(.down))
    }

    var body: some View {
        let size = Self.size(notch, stage.progress)
        NotchRootView()
            .frame(width: size.width, height: size.height)
            .background(Color.black.clipShape(NotchSilhouette(shoulder: NotchController.shoulder,
                                                              bottomRadius: 12 + 10 * min(1, max(0, stage.progress)))))
            .environmentObject(notch).environmentObject(notch.library).environmentObject(notch.player)
            .environmentObject(notch.browser).environmentObject(notch.captions)
            .preferredColorScheme(.dark)
    }
}
