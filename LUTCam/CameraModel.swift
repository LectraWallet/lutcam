import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import Photos
import UIKit
import Vision

/// One captured photo waiting on the review screen.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    /// Original ungraded image (re-graded live when the strength slider moves).
    let original: UIImage
}

enum TrackAxis: String, CaseIterable {
    case all = "All"
    case horizontal = "H"
    case vertical = "V"
    case locked = "Lock"
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

    // Zoom. maxZoom is the TOTAL cap (1000x); the part past the lens max is
    // digital (preview scaled + photo center-cropped). zoomCap is per-mode:
    // video caps at the lens max because the file recorder can't do digital.
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoom: CGFloat = 1000
    @Published var deviceMaxZoom: CGFloat = 10
    @Published var digitalZoomFactor: CGFloat = 1
    @Published var zoomCap: CGFloat = 1000

    // LUTs
    @Published var luts: [LoadedLUT] = []
    @Published var selectedLUT: LoadedLUT?
    @Published var lutStrength: Float = 0.7
    @Published var lutError: String?

    // Recording
    @Published var isRecording = false
    @Published var recordingSeconds = 0

    // Face tracking (metadata output — no frame access, preview-safe).
    @Published var faceTracking = false
    @Published var trackAxis: TrackAxis = .all
    @Published var faceRect: CGRect?

    // Point tracking (Vision object tracking on a low-res data output).
    @Published var trackRect: CGRect?

    // Preview shake stabilization (CoreMotion counter-shift, preview only).
    @Published var stabilizationEnabled = true
    @Published var stabOffset: CGSize = .zero
    @Published var stabRotation: Double = 0

    // Set by the preview view so face bounds can be converted to view space.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Capture machinery

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lutcam.session", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "lutcam.metadata", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let trackingQueue = DispatchQueue(label: "lutcam.tracking", qos: .userInitiated)
    private var trackRequest: VNTrackObjectRequest?
    private var trackFrameCounter = 0
    private var lastTrackRect: CGRect?
    private var lastPointPublish = Date.distantPast
    private var motionManager: CMMotionManager?
    private let motionQueue = OperationQueue()
    private var stabDX: Double = 0
    private var stabDY: Double = 0
    private var stabRot: Double = 0
    private var device: AVCaptureDevice?
    private var activeDelegates: [PhotoCaptureDelegate] = []
    private var observations: [NSKeyValueObservation] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var hasMicInput = false
    private var recordTimer: Timer?
    private var lastTrackPOI = CGPoint(x: 0.5, y: 0.5)
    private var lastTrackUpdate = Date.distantPast
    private var lastFaceRect: CGRect?
    private var lastFacePublish = Date.distantPast

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
        // Mic access is requested lazily, only when recording starts — never at launch.
        loadSavedLUTs()
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            if self.session.canAddOutput(self.metadataOutput) {
                self.session.addOutput(self.metadataOutput)
                self.metadataOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
                if self.metadataOutput.availableMetadataObjectTypes.contains(.face) {
                    self.metadataOutput.metadataObjectTypes = [.face]
                }
            }

            // Low-res data output for Vision point tracking. Added at configure
            // time (never mid-session). Idle-cheap: the delegate returns
            // immediately unless a track request is active.
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 360,
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                self.videoOutput.setSampleBufferDelegate(self, queue: self.trackingQueue)
            }

            self.device = device
            self.session.commitConfiguration()

            self.readRanges(from: device)
            self.observe(device: device)
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isReady = true
                self.startMotion()
            }
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
        let lensMax = max(1, device.maxAvailableVideoZoomFactor)
        DispatchQueue.main.async {
            self.isoRange = isoMin...isoMax
            self.shutterRange = shMin...max(shMin, shMax)
            self.biasRange = biasMin...biasMax
            self.deviceMaxZoom = lensMax
            self.maxZoom = 1000
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
        motionManager?.stopDeviceMotionUpdates()
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
    /// Accounts for the digital zoom crop so taps land where the user tapped.
    func focusAt(point: CGPoint) {
        let d = max(digitalZoomFactor, 1)
        let adjusted = CGPoint(
            x: min(max(0.5 + (point.x - 0.5) / d, 0), 1),
            y: min(max(0.5 + (point.y - 0.5) / d, 0), 1)
        )
        let devicePoint = CGPoint(x: adjusted.y, y: 1 - adjusted.x)
        setFocusPoint(devicePoint)
    }

    private func setFocusPoint(_ devicePoint: CGPoint) {
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
        let clamped = min(max(factor, 1), zoomCap)
        let deviceFactor = min(clamped, deviceMaxZoom)
        let digital = clamped / max(deviceFactor, 1)
        zoomFactor = clamped
        digitalZoomFactor = digital
        sessionQueue.async { [weak self] in
            self?.withDevice { device in
                device.videoZoomFactor = deviceFactor
            }
        }
    }

    // MARK: - LUT selection

    func selectLUT(_ lut: LoadedLUT?) {
        selectedLUT = lut
    }

    func setLUTStrength(_ strength: Float) {
        lutStrength = strength
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
                let final = self.applyDigitalCrop(to: image)
                DispatchQueue.main.async { self.reviewPhoto = CapturedPhoto(original: final) }
            }
            self.activeDelegates.append(delegate)
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// When the total zoom exceeds the lens max, the extra is digital: crop the
    /// center of the captured frame so the photo matches the zoomed preview.
    private func applyDigitalCrop(to image: UIImage) -> UIImage {
        let d = digitalZoomFactor
        guard d > 1.001, let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let cw = max(1, w / d), ch = max(1, h / d)
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
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

    // MARK: - Video recording (AVCaptureMovieFileOutput — preview-safe)

    /// Mic access is requested here — only when the user actually records.
    private func ensureMicAccess(_ done: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addMicInput()
            done()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted { self?.addMicInput() }
                done()
            }
        default:
            done()
        }
    }

    func startRecording() {
        ensureMicAccess { [weak self] in
            guard let self else { return }
            self.sessionQueue.async { [weak self] in
                guard let self, !self.isRecording else { return }
                if let connection = self.movieOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        // No API queries per-mode support: set the strongest
                        // mode and the system falls back to the closest one.
                        if #available(iOS 18.0, *) {
                            connection.preferredVideoStabilizationMode = .cinematicExtended
                        } else {
                            connection.preferredVideoStabilizationMode = .auto
                        }
                    }
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try? FileManager.default.removeItem(at: url)
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
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
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
    }

    private func finishRecording(success: Bool, url: URL) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordTimer?.invalidate()
            self.recordTimer = nil
        }
        if success {
            saveVideo(at: url)
        } else {
            try? FileManager.default.removeItem(at: url)
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

    // MARK: - Face tracking

    private func trackFace(_ layerRect: CGRect) {
        // A selected point wins: when point tracking is active, faces are ignored.
        guard trackRequest == nil else { return }
        followRect(layerRect)
    }

    /// Focus-follow shared by faces and the tracked point. `rect` is in
    /// view-normalized coordinates (origin top-left).
    private func followRect(_ rect: CGRect) {
        guard faceTracking else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let deviceCenter = CGPoint(x: center.y, y: 1 - center.x)
        let target: CGPoint
        switch trackAxis {
        case .all:
            target = deviceCenter
        case .horizontal:
            target = CGPoint(x: deviceCenter.x, y: lastTrackPOI.y)
        case .vertical:
            target = CGPoint(x: lastTrackPOI.x, y: deviceCenter.y)
        case .locked:
            return
        }
        let now = Date()
        let moved = abs(target.x - lastTrackPOI.x) + abs(target.y - lastTrackPOI.y)
        guard moved > 0.05 || now.timeIntervalSince(lastTrackUpdate) > 1.0 else { return }
        lastTrackPOI = target
        lastTrackUpdate = now
        setFocusPoint(target)
    }

    // MARK: - Point tracking (tap to select, Vision follows it)

    func toggleTracking() {
        faceTracking.toggle()
        if !faceTracking { stopTracking() }
    }

    /// Start tracking the object at a view-normalized point (origin top-left).
    func startTracking(at point: CGPoint) {
        let size: CGFloat = 0.14
        // Vision coordinates: origin bottom-left, in the upright (portrait) frame.
        let visionBox = CGRect(
            x: min(max(point.x - size / 2, 0), 1 - size),
            y: min(max((1 - point.y) - size / 2, 0), 1 - size),
            width: size, height: size
        )
        let viewBox = CGRect(x: visionBox.minX, y: 1 - visionBox.maxY, width: size, height: size)
        trackingQueue.async { [weak self] in
            guard let self else { return }
            let observation = VNDetectedObjectObservation(boundingBox: visionBox)
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .fast
            self.trackRequest = request
            self.trackFrameCounter = 0
            self.lastTrackRect = nil
        }
        DispatchQueue.main.async { [weak self] in self?.trackRect = viewBox }
    }

    func stopTracking() {
        trackingQueue.async { [weak self] in self?.trackRequest = nil }
        DispatchQueue.main.async { [weak self] in self?.trackRect = nil }
    }

    private func trackPoint(_ viewRect: CGRect) {
        followRect(viewRect)
    }

    // MARK: - Preview shake stabilization (CoreMotion counter-shift)

    func toggleStabilization() {
        stabilizationEnabled.toggle()
        if stabilizationEnabled {
            startMotion()
        } else {
            stopMotion()
            DispatchQueue.main.async {
                self.stabOffset = .zero
                self.stabRotation = 0
            }
        }
    }

    private func startMotion() {
        guard stabilizationEnabled else { return }
        let manager = motionManager ?? CMMotionManager()
        motionManager = manager
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        motionQueue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let dt = 1.0 / 30.0
            let focal: Double = 350 // points of shift per radian of rotation
            // Integrate rotation rates with decay: shakes cancel, slow pans recenter.
            // Signs derived from the device axes (x right, y up, z toward user):
            // positive yaw/pitch/roll move scene content left/up/counterclockwise,
            // so the preview shifts right/down/clockwise to compensate.
            self.stabDX = (self.stabDX + motion.rotationRate.y * dt * focal) * 0.88
            self.stabDY = (self.stabDY + motion.rotationRate.x * dt * focal) * 0.88
            self.stabRot = (self.stabRot + motion.rotationRate.z * dt) * 0.88
            let dx = min(max(self.stabDX, -50), 50)
            let dy = min(max(self.stabDY, -50), 50)
            let rot = min(max(self.stabRot, -0.06), 0.06)
            DispatchQueue.main.async {
                self.stabOffset = CGSize(width: dx, height: dy)
                self.stabRotation = rot
            }
        }
    }

    private func stopMotion() {
        motionManager?.stopDeviceMotionUpdates()
    }

    // MARK: - LUT storage

    private var documentsDir: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var lutsFolder: URL? {
        let folder = documentsDir?.appendingPathComponent("LUTs", isDirectory: true)
        if let folder, !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    /// Scans the Files-app-visible Documents folder: the LUTs/ subfolder first,
    /// then .cube files dropped at the Documents root. Deduplicated by name.
    /// Called at launch and when the app returns to the foreground, so files
    /// added in the Files app show up without an in-app import.
    func loadSavedLUTs() {
        var urls: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in [lutsFolder, documentsDir].compactMap({ $0 }) {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "cube" {
                let name = file.deletingPathExtension().lastPathComponent
                if seen.insert(name).inserted { urls.append(file) }
            }
        }
        var loaded: [LoadedLUT] = []
        for file in urls {
            if let lut = try? CubeLUT.parse(url: file, name: file.deletingPathExtension().lastPathComponent) {
                loaded.append(lut)
            }
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let selectedName = selectedLUT?.name
        DispatchQueue.main.async {
            self.luts = loaded
            if let selectedName, !loaded.contains(where: { $0.name == selectedName }) {
                self.selectedLUT = nil
            }
        }
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
        if let fileName = lut.fileName {
            if let folder = lutsFolder {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
            }
            if let docs = documentsDir {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(fileName))
            }
        }
        luts.removeAll { $0.id == lut.id }
        if selectedLUT?.id == lut.id { selectLUT(nil) }
    }
}

// MARK: - Movie file output delegate

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // UI state already set in startRecording.
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        finishRecording(success: error == nil, url: outputFileURL)
    }
}

// MARK: - Face metadata delegate

extension CameraModel: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let layer = previewLayer else { return }
        let faces = metadataObjects.compactMap { $0 as? AVMetadataFaceObject }
        guard let face = faces.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            if faceRect != nil {
                DispatchQueue.main.async { [weak self] in self?.faceRect = nil }
            }
            return
        }
        guard let transformed = layer.transformedMetadataObject(for: face) else { return }
        let bounds = transformed.bounds
        let normalized = CGRect(
            x: bounds.minX / max(layer.bounds.width, 1),
            y: bounds.minY / max(layer.bounds.height, 1),
            width: bounds.width / max(layer.bounds.width, 1),
            height: bounds.height / max(layer.bounds.height, 1)
        )
        let now = Date()
        let rectChanged: Bool
        if let last = lastFaceRect {
            rectChanged = abs(last.midX - normalized.midX) + abs(last.midY - normalized.midY) > 0.01
        } else {
            rectChanged = true
        }
        if rectChanged || now.timeIntervalSince(lastFacePublish) > 0.5 {
            lastFaceRect = normalized
            lastFacePublish = now
            DispatchQueue.main.async { [weak self] in self?.faceRect = normalized }
        }
        trackFace(normalized)
    }
}

// MARK: - Video data output delegate (point tracking only)

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let request = trackRequest else { return }
        trackFrameCounter += 1
        guard trackFrameCounter % 2 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // .right rotates the sensor frame upright (portrait), so the returned
        // bounding box is in the same upright space as the preview.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let result = request.results?.first as? VNDetectedObjectObservation else {
            // Tracking lost — clear so the user can re-tap the point.
            trackRequest = nil
            DispatchQueue.main.async { [weak self] in self?.trackRect = nil }
            return
        }
        let box = result.boundingBox
        let viewRect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        let now = Date()
        let changed: Bool
        if let last = lastTrackRect {
            changed = abs(last.midX - viewRect.midX) + abs(last.midY - viewRect.midY) > 0.005
        } else {
            changed = true
        }
        if changed || now.timeIntervalSince(lastPointPublish) > 0.5 {
            lastTrackRect = viewRect
            lastPointPublish = now
            DispatchQueue.main.async { [weak self] in self?.trackRect = viewRect }
        }
        trackPoint(viewRect)
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
