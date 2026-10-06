import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    enum Style: Hashable {
        case monochrome
        case brand
    }

    private struct CacheKey: Hashable {
        let provider: UsageProvider
        let style: Style
    }

    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [CacheKey: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        // SwiftPM creates a CodexBar_CodexBar.bundle for resources in the CodexBar target.
        if let bundleURL = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    static func image(for provider: UsageProvider, style: Style = .monochrome) -> NSImage? {
        let key = CacheKey(provider: provider, style: style)
        if let cached = self.cache[key] {
            return cached
        }

        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        guard let bundle = self.resourceBundle else {
            return nil
        }
        // Only explicitly curated brand assets have reliable original colors. Existing provider
        // SVGs are often white silhouettes, so they must remain templates in both appearances.
        // Different products can share a legacy monochrome resource, but not product artwork.
        let brandResourceName = "Brand-ProviderIcon-" + provider.rawValue
        let brandImage: NSImage? = style == .brand ? ["svg", "png"].lazy.compactMap { fileExtension in
            bundle.url(forResource: brandResourceName, withExtension: fileExtension)
                .flatMap { NSImage(contentsOf: $0) }
        }.first : nil
        guard let image = brandImage ?? bundle.url(forResource: baseName, withExtension: "svg")
            .flatMap({ NSImage(contentsOf: $0) }) else { return nil }

        image.size = self.size
        image.isTemplate = brandImage == nil
        self.cache[key] = image
        return image
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
    }
}
