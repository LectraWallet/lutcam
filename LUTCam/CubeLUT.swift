import CoreImage
import UIKit

/// A .cube file found on disk. Lightweight — the file is only parsed when
/// selected, so hundreds of LUTs never block launch.
struct LUTEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
}

/// A parsed .cube 3D LUT. Cube data is stored as RGBA floats, size^3 entries,
/// plus a prebuilt Data blob so live grading never copies the array per frame.
struct LoadedLUT: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: Int
    let data: [Float]
    let cubeData: Data
    /// File name in the app's LUTs folder (nil for in-memory only).
    let fileName: String?

    static func == (lhs: LoadedLUT, rhs: LoadedLUT) -> Bool { lhs.id == rhs.id }
}

enum CubeError: Error {
    case unreadable
    case noSize
    case badSize
    case notEnoughData

    var reason: String {
        switch self {
        case .unreadable: return "the file could not be read as text"
        case .noSize: return "no LUT_3D_SIZE or LUT_1D_SIZE line found"
        case .badSize: return "unsupported LUT size"
        case .notEnoughData: return "not enough color data for the stated size"
        }
    }
}

struct CubeLUT {

    /// Parse an Adobe .cube file. Supports LUT_3D_SIZE 2...64 and 1D LUTs
    /// (expanded into a 3D cube). Tolerant of BOMs, tabs, CRLF, non-UTF8
    /// encodings, and extra header lines — real-world packs vary wildly.
    /// Throws on malformed input.
    static func parse(url: URL, name: String) throws -> LoadedLUT {
        guard let data = try? Data(contentsOf: url),
              let rawText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw CubeError.unreadable
        }
        // Strip a UTF-8 BOM so the first header line still matches.
        let text = rawText.replacingOccurrences(of: "\u{FEFF}", with: "")
        var size3D: Int?
        var size1D: Int?
        var rgb: [Float] = []
        rgb.reserveCapacity(33 * 33 * 33 * 3)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size3D = firstInt(afterKey: "LUT_3D_SIZE", in: line)
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                size1D = firstInt(afterKey: "LUT_1D_SIZE", in: line)
                continue
            }
            if upper.hasPrefix("LUT_1D") || upper.hasPrefix("LUT_3D")
                || upper.hasPrefix("DOMAIN") || upper.hasPrefix("TITLE") { continue }
            // Data line: "r g b" separated by spaces and/or tabs.
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                continue
            }
            rgb.append(contentsOf: [r, g, b])
        }
        if let n = size3D {
            guard (2...64).contains(n) else { throw CubeError.badSize }
            let needed = n * n * n * 3
            guard rgb.count >= needed else { throw CubeError.notEnoughData }
            // Build RGBA float array (alpha = 1), preserving file order.
            var rgba: [Float] = []
            rgba.reserveCapacity(n * n * n * 4)
            for i in 0..<(n * n * n) {
                rgba.append(rgb[i * 3])
                rgba.append(rgb[i * 3 + 1])
                rgba.append(rgb[i * 3 + 2])
                rgba.append(1.0)
            }
            let cubeData = Data(bytes: &rgba, count: rgba.count * MemoryLayout<Float>.size)
            return LoadedLUT(name: name, size: n, data: rgba, cubeData: cubeData, fileName: url.lastPathComponent)
        }
        if let n = size1D {
            guard (2...1024).contains(n) else { throw CubeError.badSize }
            guard rgb.count >= n * 3 else { throw CubeError.notEnoughData }
            return expand1D(name: name, curve: rgb, count: n, fileName: url.lastPathComponent)
        }
        throw CubeError.noSize
    }

    /// First integer after the header key (skips the digit inside the key
    /// itself, e.g. the "3" in LUT_3D_SIZE).
    private static func firstInt(afterKey key: String, in line: String) -> Int? {
        let rest = line.dropFirst(key.count)
        return rest.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }.first
    }

    /// Expands a 1D per-channel curve into a 3D cube (each channel driven by
    /// its own coordinate), so 1D .cube files work with CIColorCube.
    private static func expand1D(name: String, curve: [Float], count n: Int, fileName: String) -> LoadedLUT {
        let m = min(n, 33)
        func sample(channel: Int, at t: Float) -> Float {
            let p = min(max(t, 0), 1) * Float(n - 1)
            let i0 = Int(p)
            let i1 = min(i0 + 1, n - 1)
            let f = p - Float(i0)
            return curve[i0 * 3 + channel] + (curve[i1 * 3 + channel] - curve[i0 * 3 + channel]) * f
        }
        var rgba: [Float] = []
        rgba.reserveCapacity(m * m * m * 4)
        for b in 0..<m {
            for g in 0..<m {
                for r in 0..<m {
                    rgba.append(sample(channel: 0, at: Float(r) / Float(m - 1)))
                    rgba.append(sample(channel: 1, at: Float(g) / Float(m - 1)))
                    rgba.append(sample(channel: 2, at: Float(b) / Float(m - 1)))
                    rgba.append(1.0)
                }
            }
        }
        let cubeData = Data(bytes: &rgba, count: rgba.count * MemoryLayout<Float>.size)
        return LoadedLUT(name: name, size: m, data: rgba, cubeData: cubeData, fileName: fileName)
    }

    /// Grade a CIImage with the LUT at the given strength (0...1). Returns the
    /// input unchanged on any failure — grading must never lose a frame.
    static func grade(_ input: CIImage, lut: LoadedLUT, strength: Float) -> CIImage {
        let clamped = min(1, max(0, strength))
        guard clamped > 0.001 else { return input }
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return input }

        guard let cubeFilter = CIFilter(name: "CIColorCube") else { return input }
        cubeFilter.setValue(lut.size, forKey: "inputCubeDimension")
        cubeFilter.setValue(lut.cubeData, forKey: "inputCubeData")
        cubeFilter.setValue(input, forKey: kCIInputImageKey)
        guard let filtered = cubeFilter.outputImage else { return input }

        if clamped >= 0.999 { return filtered }

        // Blend filtered over original with a constant mask at `strength` alpha.
        guard let maskGen = CIFilter(name: "CIConstantColorGenerator") else { return input }
        maskGen.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(clamped)), forKey: kCIInputColorKey)
        guard let mask = maskGen.outputImage?.cropped(to: extent),
              let blend = CIFilter(name: "CIBlendWithMask") else { return input }
        blend.setValue(filtered, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? input
    }

    /// Apply the LUT to an image at the given strength (0...1). Returns the
    /// original image on any failure — applying a LUT must never lose a photo.
    static func apply(to image: UIImage, lut: LoadedLUT, strength: Float, context: CIContext) -> UIImage {
        guard let ciInput = CIImage(image: image) else { return image }
        let extent = ciInput.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let result = grade(ciInput, lut: lut, strength: strength)
        guard let cg = context.createCGImage(result, from: extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}
