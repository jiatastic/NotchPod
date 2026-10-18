import SwiftUI
import AppKit
import ImageIO

struct Artwork: View {
    let url: URL?
    var fallbackURL: URL? = nil
    let size: CGFloat
    @StateObject private var loader = ArtworkLoader()

    private var sources: [URL] {
        var seen = Set<URL>()
        return [url, fallbackURL].compactMap { $0 }.filter {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && seen.insert($0).inserted
        }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(3, size * 0.16), style: .continuous)
        ZStack {
            Palette.hover
            if let image = loader.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.35)).foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Dark covers would otherwise dissolve into the black notch.
        .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: sources) { await loader.load(sources) }
        .transaction { $0.animation = nil }
    }
}

@MainActor
private final class ArtworkLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static var pending: [URL: Task<Void, Never>] = [:]

    func load(_ sources: [URL]) async {
        // A cached show cover can be visible while the episode's own image loads.
        image = sources.lazy.compactMap { Self.cache.object(forKey: $0 as NSURL) }.first
        for url in sources {
            guard !Task.isCancelled else { return }
            let result = await Self.fetch(url)
            guard !Task.isCancelled else { return }
            if let result { image = result; return }
            // Failed episode URL -> show URL -> stable placeholder. No layout jump.
        }
    }
    private static func fetch(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        // Rows sharing a show's cover also share one request and decode operation.
        if let task = pending[url] {
            await task.value
            return cache.object(forKey: url as NSURL)
        }
        let task = Task { @MainActor in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      data.count <= 12 * 1024 * 1024 else { return }
                let thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 256,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }.value
                guard let thumbnail else { return }
                let image = NSImage(cgImage: thumbnail, size: .zero)
                cache.setObject(image, forKey: url as NSURL, cost: thumbnail.bytesPerRow * thumbnail.height)
            } catch { /* The caller tries the next artwork source. */ }
        }
        pending[url] = task
        await task.value
        pending[url] = nil
        return cache.object(forKey: url as NSURL)
    }
}
