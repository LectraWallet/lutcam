import CoreImage
import UIKit

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
        let cubeData = Data(bytes: &rgba, count: rgba.count * MemoryLayout<Float>.size)
        return LoadedLUT(name: name, size: n, data: rgba, cubeData: cubeData, fileName: url.lastPathComponent)
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
