import AVFoundation
import CoreImage
import CoreVideo
import Metal
import MetalKit
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

    // Zoom. maxZoom is read from the device and capped at 100.
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoom: CGFloat = 10

    // LUTs
    @Published var luts: [LoadedLUT] = []
    @Published var selectedLUT: LoadedLUT?
    @Published var lutStrength: Float = 0.7
    @Published var lutError: String?

    // Recording
    @Published var isRecording = false
    @Published var recordingSeconds = 0

    // MARK: - Capture machinery

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lutcam.session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "lutcam.capture", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var device: AVCaptureDevice?
    private var activeDelegates: [PhotoCaptureDelegate] = []
    private var observations: [NSKeyValueObservation] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var hasMicInput = false

    // MARK: - Live preview (Metal)

    /// The on-screen Metal view, set by the SwiftUI wrapper. Weak: the view owns itself.
    weak var previewView: MTKView?
    let metalDevice = MTLCreateSystemDefaultDevice()
    private var metalContext: CIContext?
    private var commandQueue: MTLCommandQueue?

    // MARK: - Live grading recipe (lock-guarded: written on main, read on captureQueue)

    private struct GradeRecipe {
        var lut: LoadedLUT?
        var strength: Float
    }
    private var gradeRecipe = GradeRecipe(lut: nil, strength: 0.7)
    private let gradeLock = NSLock()

    // MARK: - Recording machinery (captureQueue-confined unless noted)

    private var isCapturing = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelPool: CVPixelBufferPool?
    private var recordingURL: URL?
    private var writerSessionStarted = false
    private var finishing = false
    private var videoSize: CGSize = .zero
    private var recordTimer: Timer?

    override init() {
        super.init()
        if let metalDevice {
            metalContext = CIContext(mtlDevice: metalDevice)
            commandQueue = metalDevice.makeCommandQueue()
        }
    }

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
        requestMicAccess()
        loadSavedLUTs()
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestMicAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addMicInput()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted { self?.addMicInput() }
            }
        default:
            break
        }
    }

    private func addMicInput() {
        sessionQueue.async { [weak self] in
            guard let self, !self.hasMicInput, self.session.isRunning else { return }
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic),
                  self.session.canAddInput(input) else { return }
            self.session.beginConfiguration()
            self.session.addInput(input)
            self.session.commitConfiguration()
            self.hasMicInput = true
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            } else if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }

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

            // Live video frames: graded + drawn by Metal, and written while recording.
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.captureQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.audioOutput.setSampleBufferDelegate(self, queue: self.captureQueue)
            if self.session.canAddOutput(self.audioOutput) {
                self.session.addOutput(self.audioOutput)
            }

            self.device = device
            self.session.commitConfiguration()

            self.readRanges(from: device)
            self.observe(device: device)
            self.session.startRunning()
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                self.addMicInput()
            }
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
        let zoomMax = min(max(1, device.maxAvailableVideoZoomFactor), 100)
        DispatchQueue.main.async {
            self.isoRange = isoMin...isoMax
            self.shutterRange = shMin...max(shMin, shMax)
            self.biasRange = biasMin...biasMax
            self.maxZoom = zoomMax
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
            device.observe(\.deviceWhiteBalanceGains, options: [.new]) { [weak self] d, _ in
                let t = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
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
        var gains = device.deviceWhiteBalanceGains(for: values)
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
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

    /// Tap point in view coordinates (origin top-left). Converted to the
    /// device's point-of-interest space for the portrait back camera.
    func focusAt(point: CGPoint) {
        let devicePoint = CGPoint(x: point.y, y: 1 - point.x)
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
            }
        }
    }

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        let clamped = min(max(factor, 1), maxZoom)
        zoomFactor = clamped
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                device.videoZoomFactor = clamped
            }
        }
    }

    // MARK: - LUT selection (keeps the live grading recipe in sync)

    func selectLUT(_ lut: LoadedLUT?) {
        selectedLUT = lut
        updateRecipe()
    }

    func setLUTStrength(_ strength: Float) {
        lutStrength = strength
        updateRecipe()
    }

    private func updateRecipe() {
        gradeLock.lock()
        gradeRecipe = GradeRecipe(lut: selectedLUT, strength: lutStrength)
        gradeLock.unlock()
    }

    private func currentRecipe() -> GradeRecipe {
        gradeLock.lock()
        defer { gradeLock.unlock() }
        return gradeRecipe
    }

    // MARK: - Photo capture

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
                if success { self?.flashSaved() }
            }
        }
    }

    private func flashSaved() {
        DispatchQueue.main.async {
            self.savedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.savedFlash = false }
        }
    }

    // MARK: - Video recording (LUT burned in, with audio when the mic is on)

    func startRecording() {
        captureQueue.async { [weak self] in
            guard let self, !self.isCapturing, self.writer == nil, self.videoSize.width > 0 else { return }
            let width = Int(self.videoSize.width)
            let height = Int(self.videoSize.height)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(vInput) else { return }
            writer.add(vInput)

            var aInput: AVAssetWriterInput?
            if self.hasMicInput {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    aInput = input
                }
            }

            let poolAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { return }

            self.writer = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: nil)
            self.pixelPool = pool
            self.recordingURL = url
            self.writerSessionStarted = false
            self.finishing = false
            writer.startWriting()
            self.isCapturing = true
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingSeconds = 0
                self.recordTimer?.invalidate()
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.recordingSeconds += 1
                }
            }
        }
    }

    func stopRecording() {
        captureQueue.async { [weak self] in
            guard let self, self.isCapturing, let writer = self.writer else { return }
            self.finishing = true
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let url = self.recordingURL
            writer.finishWriting { [weak self] in
                guard let self else { return }
                let success = writer.status == .completed
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.pixelPool = nil
                self.recordingURL = nil
                self.writerSessionStarted = false
                self.finishing = false
                self.isCapturing = false
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordTimer?.invalidate()
                    self.recordTimer = nil
                }
                if success, let url {
                    self.saveVideo(at: url)
                } else if let url {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func saveVideo(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }) { success, _ in
                try? FileManager.default.removeItem(at: url)
                if success { self?.flashSaved() }
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
                self.selectLUT(lut)
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
        if selectedLUT?.id == lut.id { selectLUT(nil) }
    }
}

// MARK: - Live frames: grade, draw to Metal, write while recording

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            if isCapturing, writerSessionStarted, !finishing,
               let aInput = audioInput, aInput.isReadyForMoreMediaData {
                aInput.append(sampleBuffer)
            }
            return
        }
        guard output === videoOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Sensor frames arrive landscape; rotate to portrait upright for the back camera.
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let recipe = currentRecipe()
        if let lut = recipe.lut {
            image = CubeLUT.grade(image, lut: lut, strength: recipe.strength)
        }
        let extent = image.extent
        if videoSize != extent.size { videoSize = extent.size }

        renderPreview(image)

        if isCapturing, !finishing {
            appendVideoFrame(image, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }

    private func renderPreview(_ image: CIImage) {
        guard let metalContext, let commandQueue,
              let view = previewView,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        // Aspect-fill: center-crop the frame to the drawable's aspect.
        let extent = image.extent
        let imageAspect = extent.width / extent.height
        let viewAspect = drawableSize.width / drawableSize.height
        var crop = extent
        if imageAspect > viewAspect {
            let w = extent.height * viewAspect
            crop = CGRect(x: extent.midX - w / 2, y: extent.minY, width: w, height: extent.height)
        } else {
            let h = extent.width / viewAspect
            crop = CGRect(x: extent.minX, y: extent.midY - h / 2, width: extent.width, height: h)
        }
        metalContext.render(image, to: drawable.texture, commandBuffer: commandBuffer, bounds: crop, colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func appendVideoFrame(_ image: CIImage, pts: CMTime) {
        guard let writer, writer.status == .writing,
              let vInput = videoInput, let adaptor, let pool = pixelPool,
              let metalContext else { return }
        if !writerSessionStarted {
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
        }
        guard vInput.isReadyForMoreMediaData else { return }
        var px: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px) == kCVReturnSuccess, let px else { return }
        metalContext.render(image, to: px)
        adaptor.append(px, withPresentationTime: pts)
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
