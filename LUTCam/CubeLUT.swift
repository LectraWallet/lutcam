import CoreImage
import UIKit

/// A parsed .cube 3D LUT. Cube data is stored as RGBA floats, size^3 entries.
struct LoadedLUT: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: Int
    let data: [Float]
    /// File name in the app's LUTs folder (nil for in-memory only).
    let fileName: String?

    static func == (lhs: LoadedLUT, rhs: LoadedLUT) -> Bool { lhs.id == rhs.id }
}

enum CubeError: Error {
    case unreadable
    case noSize
    case badSize
    case notEnoughData
}

struct CubeLUT {

    /// Parse an Adobe .cube file. Supports LUT_3D_SIZE 2...64. Throws on malformed input.
    static func parse(url: URL, name: String) throws -> LoadedLUT {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CubeError.unreadable
        }
        var size: Int?
        var rgb: [Float] = []
        rgb.reserveCapacity(33 * 33 * 33 * 3)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                if let last = parts.last, let n = Int(last) { size = n }
                continue
            }
            if line.hasPrefix("LUT_1D") || line.hasPrefix("DOMAIN") || line.hasPrefix("TITLE") { continue }
            // Data line: "r g b"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                continue
            }
            rgb.append(contentsOf: [r, g, b])
        }
        guard let n = size else { throw CubeError.noSize }
        guard (2...64).contains(n) else { throw CubeError.badSize }
        let needed = n * n * n * 3
        guard rgb.count >= needed else { throw CubeError.notEnoughData }
        // Build RGBA float array (alpha = 1).
        var rgba: [Float] = []
        rgba.reserveCapacity(n * n * n * 4)
        for i in 0..<(n * n * n) {
            rgba.append(rgb[i * 3])
            rgba.append(rgb[i * 3 + 1])
            rgba.append(rgb[i * 3 + 2])
            rgba.append(1.0)
        }
        return LoadedLUT(name: name, size: n, data: rgba, fileName: url.lastPathComponent)
    }

    /// Apply the LUT to an image at the given strength (0...1). Returns the
    /// original image on any failure — applying a LUT must never lose a photo.
    static func apply(to image: UIImage, lut: LoadedLUT, strength: Float, context: CIContext) -> UIImage {
        let clamped = min(1, max(0, strength))
        guard clamped > 0.001 else { return image }
        guard let ciInput = CIImage(image: image) else { return image }
        let extent = ciInput.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        var cubeData = lut.data
        let data = Data(bytes: &cubeData, count: cubeData.count * MemoryLayout<Float>.size)
        guard let cubeFilter = CIFilter(name: "CIColorCube") else { return image }
        cubeFilter.setValue(lut.size, forKey: "inputCubeDimension")
        cubeFilter.setValue(data, forKey: "inputCubeData")
        cubeFilter.setValue(ciInput, forKey: kCIInputImageKey)
        guard let filtered = cubeFilter.outputImage else { return image }

        let result: CIImage
        if clamped >= 0.999 {
            result = filtered
        } else {
            // Blend filtered over original with a constant mask at `strength` alpha.
            guard let maskGen = CIFilter(name: "CIConstantColorGenerator") else { return image }
            maskGen.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(clamped)), forKey: kCIInputColorKey)
            guard let mask = maskGen.outputImage?.cropped(to: extent),
                  let blend = CIFilter(name: "CIBlendWithMask") else { return image }
            blend.setValue(filtered, forKey: kCIInputImageKey)
            blend.setValue(ciInput, forKey: kCIInputBackgroundImageKey)
            blend.setValue(mask, forKey: kCIInputMaskImageKey)
            guard let blended = blend.outputImage else { return image }
            result = blended
        }

        guard let cg = context.createCGImage(result, from: extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}
