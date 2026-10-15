import CoreGraphics
import Foundation
import ImageIO

/// The one colour a cover is "about", lifted so it reads on the notch's black.
///
/// This is what the Dynamic Island does to its waveform: the bars take the cover's colour, not
/// the app's. The naive version — the cover's average — is almost always mud, because covers
/// are mostly shadow, skin and background, and an average of those is brown. So the pixels are
/// voted into hue buckets instead, each vote weighted by how vivid the pixel is, and the
/// winning bucket's own average is the answer. A small red logo on a grey sleeve wins over the
/// grey; a cover with no real colour in it at all gets a soft white rather than a guessed hue.
nonisolated struct ArtworkAccent: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// What a colourless cover gets. White, slightly dimmed, so a black-and-white sleeve does
    /// not light the shoulder brighter than every coloured one.
    static let neutral = ArtworkAccent(red: 0.9, green: 0.9, blue: 0.9)

    /// Decodes and reduces `data`. Cheap — the cover is thumbnailed to `sampleSide` before a
    /// single pixel is read — but still image decoding, so callers keep it off the main thread.
    static func extract(from data: Data) -> ArtworkAccent? {
        guard let pixels = samplePixels(from: data) else { return nil }
        return dominant(in: pixels)
    }

    // MARK: - Sampling

    private static let sampleSide = 32
    private static let hueBuckets = 24
    /// Below either of these a pixel is grey or near-black and does not get a vote.
    private static let minimumSaturation = 0.22
    private static let minimumBrightness = 0.18
    /// The winning bucket has to hold at least this share of the cover's pixels, or one stray
    /// coloured speck would paint the bars.
    private static let minimumShare = 0.03

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    private static func samplePixels(from data: Data) -> [RGB]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: sampleSide * 2,
                  ] as CFDictionary
              ),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var pixels: [RGB] = []
        pixels.reserveCapacity(side * side)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            pixels.append(RGB(
                red: Double(bytes[offset]) / 255 / alpha,
                green: Double(bytes[offset + 1]) / 255 / alpha,
                blue: Double(bytes[offset + 2]) / 255 / alpha
            ))
        }
        return pixels
    }

    // MARK: - Choosing

    /// Separate from decoding so the vote can be checked against hand-made pixels.
    static func dominant(in pixels: [RGB]) -> ArtworkAccent? {
        guard !pixels.isEmpty else { return nil }

        var weights = [Double](repeating: 0, count: hueBuckets)
        var counts = [Int](repeating: 0, count: hueBuckets)
        var sums = [RGB](repeating: RGB(red: 0, green: 0, blue: 0), count: hueBuckets)

        for pixel in pixels {
            let (hue, saturation, brightness) = hsb(pixel)
            guard saturation >= minimumSaturation, brightness >= minimumBrightness else { continue }
            let bucket = min(Int(hue * Double(hueBuckets)), hueBuckets - 1)
            // Vividness, squared on saturation: a fully saturated pixel is worth several washed
            // out ones, which is what makes a small bright detail beat a large dull field.
            let weight = saturation * saturation * brightness
            weights[bucket] += weight
            counts[bucket] += 1
            sums[bucket].red += pixel.red * weight
            sums[bucket].green += pixel.green * weight
            sums[bucket].blue += pixel.blue * weight
        }

        // Neighbouring buckets vote together, so a hue sitting on a bucket boundary is not
        // split in half and beaten by a weaker one that happens to sit in the middle of its own.
        let smoothed = (0 ..< hueBuckets).map { index in
            weights[index]
                + 0.5 * weights[(index + hueBuckets - 1) % hueBuckets]
                + 0.5 * weights[(index + 1) % hueBuckets]
        }
        guard let winner = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }),
              weights[winner] > 0,
              Double(counts[winner]) / Double(pixels.count) >= minimumShare
        else { return .neutral }

        let total = weights[winner]
        let average = RGB(
            red: sums[winner].red / total,
            green: sums[winner].green / total,
            blue: sums[winner].blue / total
        )
        return legible(average)
    }

    /// Lifts a colour until it holds up as a 2pt bar on black. A navy cover's navy is the right
    /// *hue* and the wrong everything else: it is the cover's colour and invisible on the notch.
    /// Brightness is raised first, because that keeps the hue honest; only a colour that is
    /// still too dark after that (deep blues and violets, which carry little luminance even at
    /// full brightness) is mixed toward white.
    private static func legible(_ color: RGB) -> ArtworkAccent {
        var (hue, saturation, brightness) = hsb(color)
        brightness = max(brightness, 0.88)
        saturation = min(saturation, 0.85)
        var lifted = rgb(hue: hue, saturation: saturation, brightness: brightness)

        var steps = 0
        while luminance(lifted) < 0.32, steps < 10 {
            lifted.red += (1 - lifted.red) * 0.12
            lifted.green += (1 - lifted.green) * 0.12
            lifted.blue += (1 - lifted.blue) * 0.12
            steps += 1
        }
        return ArtworkAccent(red: lifted.red, green: lifted.green, blue: lifted.blue)
    }

    static func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func hsb(_ color: RGB) -> (Double, Double, Double) {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum

        var hue = 0.0
        if delta > 0 {
            if maximum == color.red {
                hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, maximum)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = hue * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let offset = brightness - chroma
        return RGB(red: r + offset, green: g + offset, blue: b + offset)
    }
}

nonisolated extension ArtworkAccent.RGB {
    init(_ accent: ArtworkAccent) {
        self.init(red: accent.red, green: accent.green, blue: accent.blue)
    }
}
