import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Records the README demo from the real views and real captions: tucked strip →
/// spring open → captions playing → spring closed. Run with E2E_DEMO=1.
extension E2E {
    @MainActor static func demo(_ notch: NotchController, to url: URL) async throws {
        // Room for the open player plus the spring's overshoot.
        let canvas = CGSize(width: 760, height: (notch.geometry.capHeight + notch.detailHeight) * 1.08 + 24)
        var stage = DemoStage(notch: notch)
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: canvas.width, height: canvas.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        var frames: [(CGImage, Double)] = []
        func capture(_ progress: CGFloat, hold: Double) async {
            stage.progress = progress
            hosting.rootView = AnyView(stage.body.frame(width: canvas.width, height: canvas.height))
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 40_000_000)
            if let image = snapshot(hosting, width: Int(canvas.width)) { frames.append((image, hold)) }
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
        await hold(1, seconds: 6)
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

    @MainActor static func snapshot(_ view: NSView, width: Int) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let full = rep.cgImage else { return nil }
        // 1x keeps the GIF small enough for a README.
        let height = Int(Double(full.height) * Double(width) / Double(full.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// One frame: wallpaper, menu bar, and the real notch view at a given expansion.
@MainActor
private struct DemoStage {
    let notch: NotchController
    var progress: CGFloat = 0

    var body: some View {
        // Overshoot (progress > 1) grows the frame a little, like the real window.
        let width = notch.tuckedWidth + (notch.expandedWidth - notch.tuckedWidth) * progress + 2 * NotchController.shoulder
        let height = notch.tuckedHeight + (notch.geometry.capHeight + notch.detailHeight - notch.tuckedHeight) * progress
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.45, green: 0.30, blue: 0.48),
                                    Color(red: 0.85, green: 0.55, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .top) { Color.white.opacity(0.18).frame(height: notch.geometry.capHeight) }
            NotchRootView()
                .frame(width: max(1, width), height: max(1, height))
                .background(Color.black.clipShape(NotchSilhouette(shoulder: NotchController.shoulder,
                                                                  bottomRadius: 12 + 10 * min(1, max(0, progress)))))
        }
        .environmentObject(notch).environmentObject(notch.library).environmentObject(notch.player)
        .environmentObject(notch.browser).environmentObject(notch.captions)
        .preferredColorScheme(.dark)
    }
}
