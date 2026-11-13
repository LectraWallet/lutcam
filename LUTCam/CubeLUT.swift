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
    case badSize(Int)
    case notEnoughData

    var reason: String {
        switch self {
        case .unreadable: return "the file could not be read as text"
        case .noSize: return "no LUT_3D_SIZE or LUT_1D_SIZE line found"
        case .badSize(let n): return "unsupported LUT size (\(n))"
        case .notEnoughData: return "not enough color data for the stated size"
        }
    }
}

struct CubeLUT {

    /// Parse an Adobe .cube file. Supports LUT_3D_SIZE 2...128 — cubes
    /// larger than 33 (e.g. the common 65x65x65 cinema packs) are resampled
    /// down to 33 with trilinear interpolation, which keeps full grading
    /// quality while staying fast in Core Image. 1D LUTs are expanded into
    /// a 3D cube. Tolerant of BOMs, tabs, CRLF, non-UTF8 encodings, and
    /// extra header lines — real-world packs vary wildly. Throws on
    /// malformed input.
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
            guard (2...128).contains(n) else { throw CubeError.badSize(n) }
            let needed = n * n * n * 3
            guard rgb.count >= needed else { throw CubeError.notEnoughData }
            if n > 33 {
                return resample3D(name: name, rgb: rgb, from: n, to: 33, fileName: url.lastPathComponent)
            }
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
            guard (2...1024).contains(n) else { throw CubeError.badSize(n) }
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

    /// Resamples a large 3D cube (e.g. 65) down to a smaller grid (33) with
    /// trilinear interpolation. File order is b-outer, g-middle, r-inner.
    private static func resample3D(name: String, rgb: [Float], from n: Int, to m: Int, fileName: String) -> LoadedLUT {
        func at(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float {
            rgb[((b * n + g) * n + r) * 3 + c]
        }
        func sample(r: Float, g: Float, b: Float, channel: Int) -> Float {
            let fr = min(max(r, 0), 1) * Float(n - 1)
            let fg = min(max(g, 0), 1) * Float(n - 1)
            let fb = min(max(b, 0), 1) * Float(n - 1)
            let r0 = Int(fr), g0 = Int(fg), b0 = Int(fb)
            let r1 = min(r0 + 1, n - 1), g1 = min(g0 + 1, n - 1), b1 = min(b0 + 1, n - 1)
            let tr = fr - Float(r0), tg = fg - Float(g0), tb = fb - Float(b0)
            let c000 = at(r0, g0, b0, channel), c100 = at(r1, g0, b0, channel)
            let c010 = at(r0, g1, b0, channel), c110 = at(r1, g1, b0, channel)
            let c001 = at(r0, g0, b1, channel), c101 = at(r1, g0, b1, channel)
            let c011 = at(r0, g1, b1, channel), c111 = at(r1, g1, b1, channel)
            let c00 = c000 + (c100 - c000) * tr
            let c10 = c010 + (c110 - c010) * tr
            let c01 = c001 + (c101 - c001) * tr
            let c11 = c011 + (c111 - c011) * tr
            let c0 = c00 + (c10 - c00) * tg
            let c1 = c01 + (c11 - c01) * tg
            return c0 + (c1 - c0) * tb
        }
        var rgba: [Float] = []
        rgba.reserveCapacity(m * m * m * 4)
        for b in 0..<m {
            for g in 0..<m {
                for r in 0..<m {
                    let fr = Float(r) / Float(m - 1)
                    let fg = Float(g) / Float(m - 1)
                    let fb = Float(b) / Float(m - 1)
                    rgba.append(sample(r: fr, g: fg, b: fb, channel: 0))
                    rgba.append(sample(r: fr, g: fg, b: fb, channel: 1))
                    rgba.append(sample(r: fr, g: fg, b: fb, channel: 2))
                    rgba.append(1.0)
                }
            }
        }
        let cubeData = Data(bytes: &rgba, count: rgba.count * MemoryLayout<Float>.size)
        return LoadedLUT(name: name, size: m, data: rgba, cubeData: cubeData, fileName: fileName)
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

// MARK: - Per-LUT best settings (from the LUT Guide measurements)

// When a LUT is selected, the app auto-applies its measured best settings:
// strength, ISO, shutter, white balance, and EV — and turns off the autos
// for the controls it sets, so the look matches the guide. Generated from
// lut-data.json; names match on normalized (lowercase, alphanumerics-only)
// form so "Warm_Autumn.cube" matches "Warm Autumn".

struct LUTPreset {
    let intensity: Float
    let iso: Float?
    let shutter: Double?
    let kelvin: Float?
    let ev: Float
    let summary: String
}

enum LUTPresets {
    static func preset(for lutName: String) -> LUTPreset? {
        table[normalize(lutName)]
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let table: [String: LUTPreset] = [
        "16mmpocketcameralut": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "8mmpocketcamlut": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "americanchristmas": LUTPreset(intensity: 0.85, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: -0.3, summary: "85% · ISO 100 · 1/250 · 5500K · EV -0.3"),
        "applelogtorec709v10": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "arabica12": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "arrilogctorec709widegamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "autumncrane": LUTPreset(intensity: 0.65, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "65% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "autumndaypoem": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 6000K · EV 0"),
        "autumndayscroll": LUTPreset(intensity: 0.70, iso: 50, shutter: 1.0/1000, kelvin: 5500, ev: -0.3, summary: "70% · ISO 50 · 1/1000 · 5500K · EV -0.3"),
        "ava614": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "azrael93": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "blackmagicfilmgen5torec709widegamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "bourbon64": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "byers11": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "canonlogtorec709cinemagamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "canonlog2torec709cinemagamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "canonlog3torec709cinemagamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "chemical168": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "choihungestate02": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "christmaswish": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/125, kelvin: 5000, ev: 0.0, summary: "80% · ISO 200 · 1/125 · 5000K · EV 0"),
        "chromaticcream": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "cinelite": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "cine1": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cine2": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 6000K · EV 0"),
        "cine4": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cinelikedtorec709": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "cinema3": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5800K · EV +0.3"),
        "cinematic": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cinematicgreen": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 6000K · EV 0"),
        "cinematicretrofilmlook": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cinematicforflog": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "cinestylescurve": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cityashlight": LUTPreset(intensity: 0.60, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.7, summary: "60% · ISO 200 · 1/500 · 5500K · EV +0.7"),
        "clayton33": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cleancommercial": LUTPreset(intensity: 0.80, iso: 50, shutter: 1.0/1000, kelvin: 5500, ev: -0.3, summary: "80% · ISO 50 · 1/1000 · 5500K · EV -0.3"),
        "clouseau54": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "coamorec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "coastalbreeze": LUTPreset(intensity: 0.80, iso: 50, shutter: 1.0/1000, kelvin: 5500, ev: -0.3, summary: "80% · ISO 50 · 1/1000 · 5500K · EV -0.3"),
        "cobi3": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cocalrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cold": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "colorpunch": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "coloradorec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "colorfulcandysnow": LUTPreset(intensity: 0.70, iso: 50, shutter: 1.0/2000, kelvin: 5500, ev: 0.3, summary: "70% · ISO 50 · 1/2000 · 5500K · EV +0.3"),
        "colorifyclarrilut": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 5500K · EV 0"),
        "colorifyclsunsetlut": LUTPreset(intensity: 0.70, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "70% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "contrail35": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "correctioncine": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 6000K · EV 0"),
        "cruzrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cubanismo": LUTPreset(intensity: 0.40, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "40% · ISO 100 · 1/500 · 5500K · EV 0"),
        "cubicle99": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.3, summary: "60% · ISO 100 · 1/500 · 6000K · EV +0.3"),
        "culebrarec709": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 6000K · EV 0"),
        "cuyonrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "darkgreen33pt7a00804210712c007": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "deepautumn": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: -0.3, summary: "80% · ISO 100 · 1/500 · 5800K · EV -0.3"),
        "deseadorec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "directions23c0100": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "dirtytown": LUTPreset(intensity: 0.50, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "50% · ISO 200 · 1/500 · 5500K · EV 0"),
        "distantteal": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "django25": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "djidlogtorec709djidgamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "domingo145": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "dreamblue": LUTPreset(intensity: 0.60, iso: 50, shutter: 1.0/1000, kelvin: 5500, ev: -0.3, summary: "60% · ISO 50 · 1/1000 · 5500K · EV -0.3"),
        "dulcerec709": LUTPreset(intensity: 0.50, iso: 100, shutter: 1.0/500, kelvin: 6200, ev: 0.0, summary: "50% · ISO 100 · 1/500 · 6200K · EV 0"),
        "enhance": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "erdemfilmsnightvisiongx804p1010446": LUTPreset(intensity: 0.80, iso: 800, shutter: 1.0/60, kelvin: nil, ev: 0.0, summary: "80% · ISO 800 · 1/60 · EV 0"),
        "etherealblue": LUTPreset(intensity: 0.80, iso: 50, shutter: 1.0/1000, kelvin: 5500, ev: -0.3, summary: "80% · ISO 50 · 1/1000 · 5500K · EV -0.3"),
        "explorersvibe": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "faded47": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 5500K · EV 0"),
        "fajardorec709": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 6000K · EV 0"),
        "fashion": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "film": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "film09871": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "filmbroeditorialpunch": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "firstcold": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "folger50": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "fujivivid8543": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "fusion88": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 6000K · EV 0"),
        "goldendrive03": LUTPreset(intensity: 0.50, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "50% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "goldendrive04": LUTPreset(intensity: 0.60, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "60% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "goldendrive05": LUTPreset(intensity: 0.50, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "50% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "goldensunset": LUTPreset(intensity: 0.70, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "70% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "granderec709": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 6000K · EV 0"),
        "gray": LUTPreset(intensity: 1.00, iso: 200, shutter: 1.0/250, kelvin: 6500, ev: 0.7, summary: "100% · ISO 200 · 1/250 · 6500K · EV +0.7"),
        "guayorec709": LUTPreset(intensity: 0.40, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "40% · ISO 100 · 1/500 · 5500K · EV 0"),
        "guraborec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "hoanghon": LUTPreset(intensity: 0.40, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: 0.7, summary: "40% · ISO 50 · 1/500 · 5500K · EV +0.7"),
        "hyla68": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "indiorec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "interiorv1mydo": LUTPreset(intensity: 0.55, iso: 400, shutter: 1.0/125, kelvin: 4000, ev: 0.0, summary: "55% · ISO 400 · 1/125 · 4000K · EV 0"),
        "japanlut001": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "japanlut002": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "japanlut003": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "japanlut004": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "japanlut005": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "jokerlook": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "juanrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "jungleteal": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "korben214": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "lamnoibatmausac": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "lastday1p1055707": LUTPreset(intensity: 0.50, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "50% · ISO 100 · 1/500 · 5500K · EV -0.3"),
        "lateautumnmood": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5800K · EV 0"),
        "lenox340": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: -0.3, summary: "80% · ISO 100 · 1/500 · 5800K · EV -0.3"),
        "lightv1mydo": LUTPreset(intensity: 0.50, iso: 50, shutter: 1.0/2000, kelvin: 5500, ev: -0.3, summary: "50% · ISO 50 · 1/2000 · 5500K · EV -0.3"),
        "lightv2mydo": LUTPreset(intensity: 0.50, iso: 50, shutter: 1.0/2000, kelvin: 5500, ev: -0.3, summary: "50% · ISO 50 · 1/2000 · 5500K · EV -0.3"),
        "limayrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "loizarec709": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 6000K · EV +0.3"),
        "lovestory1": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/250, kelvin: 6000, ev: 0.0, summary: "60% · ISO 100 · 1/250 · 6000K · EV 0"),
        "lovestory2": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "lovestory3": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "lovestory4": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "lovestory5": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5800K · EV 0"),
        "lucky64": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "lutphim04phongcachphimthanhpho": LUTPreset(intensity: 0.40, iso: 100, shutter: 1.0/500, kelvin: 6200, ev: 0.0, summary: "40% · ISO 100 · 1/500 · 6200K · EV 0"),
        "lutphim05tonglacay": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "lutienanh04hieuungbangmophusuong": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 6000K · EV 0"),
        "lutienanh05chieusaukhonggian": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "lutienanh06huyenaomehoac": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "majadarec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "maltilderec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "mckinnon75": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "midnightglow": LUTPreset(intensity: 0.80, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: 0.0, summary: "80% · ISO 400 · 1/125 · 4500K · EV 0"),
        "milo5": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "moodybluev1mydo": LUTPreset(intensity: 0.40, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: -0.3, summary: "40% · ISO 400 · 1/125 · 4500K · EV -0.3"),
        "moonrisecolor": LUTPreset(intensity: 0.80, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: 0.0, summary: "80% · ISO 400 · 1/125 · 4500K · EV 0"),
        "mythicalaura": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 6000K · EV +0.3"),
        "neon770": LUTPreset(intensity: 0.80, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: 0.0, summary: "80% · ISO 400 · 1/125 · 4500K · EV 0"),
        "nomadsunrise": LUTPreset(intensity: 0.60, iso: 50, shutter: 1.0/500, kelvin: 6000, ev: -0.3, summary: "60% · ISO 50 · 1/500 · 6000K · EV -0.3"),
        "obsidianhaze": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "onlyotmydo": LUTPreset(intensity: 0.50, iso: nil, shutter: 1.0/1600, kelvin: 5500, ev: 0.3, summary: "50% · 1/1600 · 5500K · EV +0.3"),
        "paladin1875": LUTPreset(intensity: 0.40, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.7, summary: "40% · ISO 100 · 1/500 · 5500K · EV +0.7"),
        "panasonicvlogtorec709vgamut": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "pasadena21": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "pastillorec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "pitaya15": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.7, summary: "60% · ISO 100 · 1/500 · 5500K · EV +0.7"),
        "platarec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "presetcuratorcfe50mmcinematiclooklut": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "presetcuratorcfe35mmfilmemulation": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "presetcuratorcfeanalogdream": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "70% · ISO 100 · 1/500 · 5500K · EV 0"),
        "presetcuratorcfeeternalcelluloid": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "redfilmchristmas": LUTPreset(intensity: 0.75, iso: 200, shutter: 1.0/125, kelvin: 5000, ev: -0.3, summary: "75% · ISO 200 · 1/125 · 5000K · EV -0.3"),
        "redlog3g10torec709redwidegamutrgb": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "redwish": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "redgamma4torec709redwidegamutrgb": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "redlogfilmtorec709redwidegamutrgb": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "reeve38": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "remy24": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "sonyslog3torec709sonysgamut3cine": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "sprocket231": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "stalmanfilm03applelog": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "stalmanfilm04applelog": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "sunnyautumn": LUTPreset(intensity: 0.80, iso: 50, shutter: 1.0/2000, kelvin: 5500, ev: -0.7, summary: "80% · ISO 50 · 1/2000 · 5500K · EV -0.7"),
        "to": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "tanamarec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "tangbaohoada": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "tealorangeforflog": LUTPreset(intensity: 1.00, iso: nil, shutter: 1.0/500, kelvin: nil, ev: 0.0, summary: "100% · 1/500 · EV 0"),
        "teigen28": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "thiennhien": LUTPreset(intensity: 0.50, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "50% · ISO 100 · 1/500 · 6000K · EV 0"),
        "trent18": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "tweed71": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "twilightember": LUTPreset(intensity: 0.40, iso: 50, shutter: 1.0/500, kelvin: 5500, ev: -0.3, summary: "40% · ISO 50 · 1/500 · 5500K · EV -0.3"),
        "universallutnightoverlay": LUTPreset(intensity: 0.60, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: 0.7, summary: "60% · ISO 400 · 1/125 · 4500K · EV +0.7"),
        "universallutouterspaceoverlay": LUTPreset(intensity: 0.80, iso: 400, shutter: 1.0/125, kelvin: 4500, ev: 0.0, summary: "80% · ISO 400 · 1/125 · 4500K · EV 0"),
        "urbanlut001": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 200 · 1/500 · 5500K · EV 0"),
        "urbanlut002": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 200 · 1/500 · 5500K · EV 0"),
        "urbanlut003": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 200 · 1/500 · 5500K · EV 0"),
        "urbanlut004": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 200 · 1/500 · 5500K · EV 0"),
        "urbanlut005": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 200 · 1/500 · 5500K · EV 0"),
        "usabonrec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5800, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5800K · EV 0"),
        "vireo37": LUTPreset(intensity: 0.70, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "70% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "vivirec709": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "wanderlustglow": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/500 · 5500K · EV 0"),
        "warmautumn": LUTPreset(intensity: 0.75, iso: 50, shutter: 1.0/1600, kelvin: 5500, ev: -0.3, summary: "75% · ISO 50 · 1/1600 · 5500K · EV -0.3"),
        "weddingluts3": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "weddingluts4": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/250, kelvin: 5500, ev: 0.0, summary: "80% · ISO 100 · 1/250 · 5500K · EV 0"),
        "winterdaylight": LUTPreset(intensity: 0.60, iso: 50, shutter: 1.0/2000, kelvin: 5500, ev: 0.3, summary: "60% · ISO 50 · 1/2000 · 5500K · EV +0.3"),
        "winterfilm": LUTPreset(intensity: 0.80, iso: 200, shutter: 1.0/500, kelvin: 6000, ev: 0.3, summary: "80% · ISO 200 · 1/500 · 6000K · EV +0.3"),
        "winterlove": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "60% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "wwlook": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 6000, ev: 0.0, summary: "60% · ISO 100 · 1/500 · 6000K · EV 0"),
        "zed32": LUTPreset(intensity: 0.80, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.3, summary: "80% · ISO 100 · 1/500 · 5500K · EV +0.3"),
        "zeke39": LUTPreset(intensity: 0.60, iso: 100, shutter: 1.0/500, kelvin: 5500, ev: 0.7, summary: "60% · ISO 100 · 1/500 · 5500K · EV +0.7"),
    ]
}
