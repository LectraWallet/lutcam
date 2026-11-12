import AVFoundation
import CoreImage
import Photos
import UIKit

/// One captured photo waiting on the review screen.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    /// Original ungraded image (re-graded live when the strength slider moves).
    let original: UIImage
}

final class CameraModel: NSObject, ObservableObject {

    // MARK: - Published state (main thread only)

    @Published var isReady = false
    @Published var permissionDenied = false
    @Published var reviewPhoto: CapturedPhoto?
    @Published var savedFlash = false

    // Live values read from the device (shown when a control is on Auto).
    @Published var liveISO: Float = 0
    @Published var liveShutter: Double = 0
    @Published var liveWB: Float = 5500
    @Published var liveLensPosition: Float = 0.5

    // Device capability ranges, filled in during setup.
    @Published var isoRange: ClosedRange<Float> = 50...800
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    @Published var wbRange: ClosedRange<Float> = 2500...10000
    @Published var biasRange: ClosedRange<Float> = -3...3

    // Control state. Exposure auto governs ISO + shutter together: iOS locks
    // both at once in custom exposure mode, so one toggle is the honest UI.
    @Published var exposureAuto = true
    @Published var manualISO: Float = 100
    @Published var manualShutter: Double = 1.0 / 120
    @Published var wbAuto = true
    @Published var manualWB: Float = 5500
    @Published var focusAuto = true
    @Published var manualFocus: Float = 0.5
    @Published var exposureBias: Float = 0

    // LUTs
    @Published var luts: [LoadedLUT] = []
    @Published var selectedLUT: LoadedLUT?
    @Published var lutStrength: Float = 0.7
    @Published var lutError: String?

    // MARK: - Capture machinery

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lutcam.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var activeDelegates: [PhotoCaptureDelegate] = []
    private var observations: [NSKeyValueObservation] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Setup

    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
        loadSavedLUTs()
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.session.addInput(input)

            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.session.addOutput(self.photoOutput)
            self.device = device
            self.session.commitConfiguration()

            self.readRanges(from: device)
            self.observe(device: device)
            self.session.startRunning()
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    private func readRanges(from device: AVCaptureDevice) {
        let format = device.activeFormat
        let isoMin = max(1, format.minISO)
        let isoMax = max(isoMin, format.maxISO)
        let minDur = CMTimeGetSeconds(format.minExposureDuration)
        let maxDur = CMTimeGetSeconds(format.maxExposureDuration)
        let shMin = (minDur > 0 && minDur.isFinite) ? minDur : (1.0 / 8000)
        let shMax = (maxDur > 0 && maxDur.isFinite) ? min(maxDur, 1.0) : (1.0 / 30)
        let biasMin = device.minExposureTargetBias
        let biasMax = device.maxExposureTargetBias
        DispatchQueue.main.async {
            self.isoRange = isoMin...isoMax
            self.shutterRange = shMin...max(shMin, shMax)
            self.biasRange = biasMin...biasMax
            self.manualISO = min(max(100, isoMin), isoMax)
            self.manualShutter = min(max(1.0 / 120, shMin), max(shMin, shMax))
        }
    }

    private func observe(device: AVCaptureDevice) {
        observations = [
            device.observe(\.iso, options: [.new]) { [weak self] d, _ in
                DispatchQueue.main.async { self?.liveISO = d.iso }
            },
            device.observe(\.exposureDuration, options: [.new]) { [weak self] d, _ in
                let s = CMTimeGetSeconds(d.exposureDuration)
                guard s.isFinite, s > 0 else { return }
                DispatchQueue.main.async { self?.liveShutter = s }
            },
            device.observe(\.whiteBalanceGains, options: [.new]) { [weak self] d, _ in
                let t = d.temperatureAndTintValues(for: d.whiteBalanceGains)
                DispatchQueue.main.async { self?.liveWB = t.temperature }
            },
            device.observe(\.lensPosition, options: [.new]) { [weak self] d, _ in
                DispatchQueue.main.async { self?.liveLensPosition = d.lensPosition }
            },
        ]
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    // MARK: - Safe device configuration

    /// Runs `block` with the device locked. Returns false if locking failed.
    private func withDevice(_ block: (AVCaptureDevice) -> Void) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            block(device)
        } catch {
            // Locking failed (device busy) — ignore silently, never crash.
        }
    }

    // MARK: - Exposure (ISO + shutter share one auto mode)

    func setExposureAuto(_ auto: Bool) {
        exposureAuto = auto
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                if auto {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                } else {
                    self?.applyCustomExposure(to: device)
                }
            }
        }
    }

    func setManualISO(_ iso: Float) {
        manualISO = iso
        guard !exposureAuto else { return }
        sessionQueue.async { [weak self] in
            self?.withDevice { device in self?.applyCustomExposure(to: device) }
        }
    }

    func setManualShutter(_ seconds: Double) {
        manualShutter = seconds
        guard !exposureAuto else { return }
        sessionQueue.async { [weak self] in
            self?.withDevice { device in self?.applyCustomExposure(to: device) }
        }
    }

    private func applyCustomExposure(to device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }
        let iso = min(max(manualISO, isoRange.lowerBound), isoRange.upperBound)
        let seconds = min(max(manualShutter, shutterRange.lowerBound), shutterRange.upperBound)
        let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
    }

    func setExposureBias(_ ev: Float) {
        exposureBias = ev
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                guard device.isExposureTargetBiasSupported else { return }
                let clamped = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
            }
        }
    }

    // MARK: - White balance

    func setWBAuto(_ auto: Bool) {
        wbAuto = auto
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                if auto {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                } else {
                    self?.applyManualWB(to: device)
                }
            }
        }
    }

    func setManualWB(_ kelvin: Float) {
        manualWB = kelvin
        guard !wbAuto else { return }
        sessionQueue.async { [weak self] in
            self?.withDevice { device in self?.applyManualWB(to: device) }
        }
    }

    private func applyManualWB(to device: AVCaptureDevice) {
        guard device.isWhiteBalanceModeSupported(.locked) else { return }
        let kelvin = min(max(manualWB, wbRange.lowerBound), wbRange.upperBound)
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
        var gains = device.deviceGainForTemperatureAndTintValues(values)
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        do {
            try device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } catch {
            // Unsupported gain combination — leave white balance as-is.
        }
    }

    // MARK: - Focus

    func setFocusAuto(_ auto: Bool) {
        focusAuto = auto
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                if auto {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                } else {
                    self?.applyManualFocus(to: device)
                }
            }
        }
    }

    func setManualFocus(_ position: Float) {
        manualFocus = position
        guard !focusAuto else { return }
        sessionQueue.async { [weak self] in
            self?.withDevice { device in self?.applyManualFocus(to: device) }
        }
    }

    private func applyManualFocus(to device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else { return }
        device.setFocusModeLocked(lensPosition: min(max(manualFocus, 0), 1), completionHandler: nil)
    }

    func focusAt(point: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
            }
        }
    }

    // MARK: - Capture

    func capture() {
        sessionQueue.async { [weak self] in
            guard let self, photoOutput.connection(with: .video) != nil else { return }
            var settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .balanced
            let delegate = PhotoCaptureDelegate { [weak self] token, image in
                guard let self else { return }
                self.sessionQueue.async {
                    self.activeDelegates.removeAll { $0.token == token }
                }
                guard let image else { return }
                DispatchQueue.main.async { self.reviewPhoto = CapturedPhoto(original: image) }
            }
            self.activeDelegates.append(delegate)
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// Grade an image with the currently selected LUT + strength (or return it unchanged).
    func graded(_ image: UIImage, strength: Float) -> UIImage {
        guard let lut = selectedLUT else { return image }
        return CubeLUT.apply(to: image, lut: lut, strength: strength, context: ciContext)
    }

    func save(image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { return }
            guard let data = image.jpegData(compressionQuality: 0.92) else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { success, _ in
                if success {
                    DispatchQueue.main.async {
                        self?.savedFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.savedFlash = false }
                    }
                }
            }
        }
    }

    // MARK: - LUT storage

    private var lutsFolder: URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let folder = docs?.appendingPathComponent("LUTs", isDirectory: true)
        if let folder, !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func loadSavedLUTs() {
        guard let folder = lutsFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        var loaded: [LoadedLUT] = []
        for file in files where file.pathExtension.lowercased() == "cube" {
            if let lut = try? CubeLUT.parse(url: file, name: file.deletingPathExtension().lastPathComponent) {
                loaded.append(lut)
            }
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.luts = loaded }
    }

    /// Import a .cube from the file picker. Copies it into the app's LUTs folder so it persists.
    func importLUT(from url: URL) {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "cube" else {
            lutError = "That file is not a .cube LUT."
            return
        }
        guard let folder = lutsFolder else { return }
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            lutError = "Could not copy that LUT file."
            return
        }
        do {
            let lut = try CubeLUT.parse(url: dest, name: dest.deletingPathExtension().lastPathComponent)
            DispatchQueue.main.async {
                self.luts.removeAll { $0.name == lut.name }
                self.luts.append(lut)
                self.luts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.selectedLUT = lut
                self.lutError = nil
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            lutError = "That .cube file could not be read. It may be damaged."
        }
    }

    func deleteLUT(_ lut: LoadedLUT) {
        if let fileName = lut.fileName, let folder = lutsFolder {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
        }
        luts.removeAll { $0.id == lut.id }
        if selectedLUT?.id == lut.id { selectedLUT = nil }
    }
}

// MARK: - Photo capture delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let token = UUID()
    private let completion: (UUID, UIImage?) -> Void
    init(completion: @escaping (UUID, UIImage?) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(token, nil)
            return
        }
        completion(token, image)
    }
}
