import CoreML
import UIKit

enum UpscaleError: LocalizedError, Equatable {
    case modelMissing
    case compileFailed(String)
    case loadFailed(String)
    case predictionFailed
    case imageFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "The AI model is missing from the app."
        case .compileFailed(let detail): return "The AI model could not be prepared on this phone. (\(detail))"
        case .loadFailed(let detail): return "The AI model could not be loaded. (\(detail))"
        case .predictionFailed: return "Upscaling failed on this photo."
        case .imageFailed: return "That photo could not be read."
        case .cancelled: return "Upscaling was cancelled."
        }
    }
}

/// On-device 4x AI upscaler: Real-ESRGAN general-x4v3, converted to CoreML,
/// running on the Neural Engine. No server, no key, works offline.
///
/// The model takes fixed 256x256 tiles, so photos are split with overlap and
/// stitched back together. Input is capped at 2048px on the longest side:
/// 4x of a full 12MP photo would need a ~780MB output buffer.
final class Upscaler {
    static let shared = Upscaler()

    private let tile = 256
    private let pad = 16
    private let scale = 4
    private let maxInputSide = 2048
    private let outputName = "var_584"

    private var model: MLModel?
    private let lock = NSLock()

    private init() {}

    // MARK: - Model loading

    /// Prefers the .mlmodelc compiled at build time (bundled in the app).
    /// Falls back to compiling the .mlpackage on-device from the flat bundle
    /// resources if the build-time compile didn't land in the bundle.
    private func loadModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let compiledDir = support.appendingPathComponent("RealESRGAN.mlmodelc", isDirectory: true)
        let compiledURL: URL
        if let bundled = Bundle.main.url(forResource: "RealESRGAN", withExtension: "mlmodelc") {
            compiledURL = bundled
        } else if fm.fileExists(atPath: compiledDir.path) {
            compiledURL = compiledDir
        } else {
            // Rebuild the .mlpackage from the flat bundle resources, then compile it.
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let package = caches.appendingPathComponent("RealESRGAN.mlpackage", isDirectory: true)
            try? fm.removeItem(at: package)
            let coreMLDir = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
            let weightsDir = coreMLDir.appendingPathComponent("weights", isDirectory: true)
            do {
                try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)
                guard let manifest = Bundle.main.url(forResource: "RealESRGAN-Manifest", withExtension: "json"),
                      let modelFile = Bundle.main.url(forResource: "RealESRGAN-model", withExtension: "bindata"),
                      let weights = Bundle.main.url(forResource: "RealESRGAN-weights", withExtension: "bin") else {
                    throw UpscaleError.modelMissing
                }
                try fm.copyItem(at: manifest, to: package.appendingPathComponent("Manifest.json"))
                try fm.copyItem(at: modelFile, to: coreMLDir.appendingPathComponent("model.mlmodel"))
                try fm.copyItem(at: weights, to: weightsDir.appendingPathComponent("weight.bin"))
                let compiled = try MLModel.compileModel(at: package)
                try? fm.removeItem(at: compiledDir)
                try fm.moveItem(at: compiled, to: compiledDir)
                compiledURL = compiledDir
            } catch {
                try? fm.removeItem(at: package)
                if let upscaleError = error as? UpscaleError { throw upscaleError }
                throw UpscaleError.compileFailed((error as NSError).localizedDescription)
            }
            try? fm.removeItem(at: package)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let loaded = try MLModel(contentsOf: compiledURL, configuration: config)
            model = loaded
            return loaded
        } catch {
            // A stale or broken on-device compiled model: delete it so the next run recompiles.
            if compiledURL == compiledDir {
                try? fm.removeItem(at: compiledDir)
            }
            throw UpscaleError.loadFailed((error as NSError).localizedDescription)
        }
    }

    // MARK: - Upscaling (call from a background queue)

    /// Upscales `image` 4x. `progress` is called with 0...1 on the calling thread.
    func upscale(_ image: UIImage, isCancelled: () -> Bool, progress: (Double) -> Void) throws -> UIImage {
        let model = try loadModel()
        guard let cg = normalizedCGImage(image) else { throw UpscaleError.imageFailed }

        let capped = cappedCGImage(cg, maxSide: maxInputSide)
        let w = capped.width, h = capped.height
        guard let src = readRGBA(capped) else { throw UpscaleError.imageFailed }

        let outW = w * scale, outH = h * scale
        guard let outCtx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                     bytesPerRow: outW * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let outData = outCtx.data else { throw UpscaleError.imageFailed }
        let outPtr = outData.bindMemory(to: UInt8.self, capacity: outW * outH * 4)

        let stride = tile - pad * 2
        let nx = (w + stride - 1) / stride
        let ny = (h + stride - 1) / stride
        let total = nx * ny
        var done = 0

        for ty in 0..<ny {
            for tx in 0..<nx {
                if isCancelled() { throw UpscaleError.cancelled }
                let ox = tx * stride - pad
                let oy = ty * stride - pad
                let input = try makeInputArray(src: src, width: w, height: h, originX: ox, originY: oy)
                let output = try predict(model: model, input: input)
                let dstX = tx * stride * scale
                let dstY = ty * stride * scale
                writeOutput(output, to: outPtr, outWidth: outW,
                            dstX: dstX, dstY: dstY,
                            copyW: min(stride * scale, outW - dstX),
                            copyH: min(stride * scale, outH - dstY))
                done += 1
                progress(Double(done) / Double(total))
            }
        }
        guard let outImage = outCtx.makeImage() else { throw UpscaleError.imageFailed }
        return UIImage(cgImage: outImage)
    }

    // MARK: - Image helpers

    /// Returns a CGImage with the UIImage's orientation baked in.
    private func normalizedCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        guard image.cgImage != nil else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let renderer = UIGraphicsImageRenderer(size: px, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: px)) }.cgImage
    }

    private func cappedCGImage(_ cg: CGImage, maxSide: Int) -> CGImage {
        let longest = max(cg.width, cg.height)
        guard longest > maxSide else { return cg }
        let s = CGFloat(maxSide) / CGFloat(longest)
        let nw = max(1, Int((CGFloat(cg.width) * s).rounded()))
        let nh = max(1, Int((CGFloat(cg.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: nw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? cg
    }

    /// Raw RGBA8 bytes, row 0 = first row of the context buffer.
    private func readRGBA(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    // MARK: - Model I/O

    /// Builds the model's [1, 3, 256, 256] float input from a window of the
    /// source image, edge-clamping reads outside the image.
    private func makeInputArray(src: [UInt8], width w: Int, height h: Int,
                                originX ox: Int, originY oy: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)],
                                   dataType: .float32)
        let plane = tile * tile
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        src.withUnsafeBufferPointer { buf in
            for y in 0..<tile {
                let sy = min(max(oy + y, 0), h - 1)
                for x in 0..<tile {
                    let sx = min(max(ox + x, 0), w - 1)
                    let si = (sy * w + sx) * 4
                    let di = y * tile + x
                    ptr[di] = Float(buf[si]) / 255
                    ptr[plane + di] = Float(buf[si + 1]) / 255
                    ptr[2 * plane + di] = Float(buf[si + 2]) / 255
                }
            }
        }
        return arr
    }

    private func predict(model: MLModel, input: MLMultiArray) throws -> MLMultiArray {
        let out = try model.prediction(from: SingleInputProvider(input: input))
        guard let arr = out.featureValue(for: outputName)?.multiArrayValue else {
            throw UpscaleError.predictionFailed
        }
        return arr
    }

    /// Copies the valid center of a 1024x1024 model output into the output buffer.
    private func writeOutput(_ arr: MLMultiArray, to outPtr: UnsafeMutablePointer<UInt8>,
                             outWidth: Int, dstX: Int, dstY: Int, copyW: Int, copyH: Int) {
        let outTile = tile * scale
        let plane = outTile * outTile
        let skip = pad * scale
        // Output is float32 per the model spec; tolerate float16 just in case.
        let read: (Int) -> Float
        if arr.dataType == .float32 {
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
            read = { p[$0] }
        } else {
            let p = arr.dataPointer.bindMemory(to: UInt16.self, capacity: 3 * plane)
            read = { Float(Float16(bitPattern: p[$0])) }
        }
        for y in 0..<copyH {
            let sy = skip + y
            for x in 0..<copyW {
                let sx = skip + x
                let di = sy * outTile + sx
                let oi = ((dstY + y) * outWidth + (dstX + x)) * 4
                outPtr[oi] = clampByte(read(di))
                outPtr[oi + 1] = clampByte(read(plane + di))
                outPtr[oi + 2] = clampByte(read(2 * plane + di))
                outPtr[oi + 3] = 255
            }
        }
    }

    private func clampByte(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, (v * 255).rounded())))
    }
}

/// Minimal feature provider: the model has exactly one input, "input".
/// (MLFeatureProvider is a class-only protocol, so this must be a class.)
private final class SingleInputProvider: NSObject, MLFeatureProvider {
    let input: MLMultiArray
    init(input: MLMultiArray) {
        self.input = input
        super.init()
    }
    var featureNames: Set<String> { ["input"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == "input" ? MLFeatureValue(multiArray: input) : nil
    }
}
