import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Glass helpers (materials render as Liquid Glass on iOS 26+)

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.14), lineWidth: 0.5))
    }
}

extension View {
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
    func glassPanel(radius: CGFloat = 24) -> some View { modifier(GlassPanel(radius: radius)) }
}

// MARK: - Live preview (system preview layer — the layer IS the view's backing
// layer, so it always matches the view bounds; no manual frame sizing)

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct LiveCameraView: UIViewRepresentable {
    @ObservedObject var model: CameraModel

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = model.session
        view.previewLayer.videoGravity = .resizeAspectFill
        model.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        if view.previewLayer.session !== model.session {
            view.previewLayer.session = model.session
        }
        model.previewLayer = view.previewLayer
        if let connection = view.previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoStabilizationSupported {
                // Strongest mode for the preview too; the system falls back
                // to the closest supported mode.
                if #available(iOS 18.0, *) {
                    connection.preferredVideoStabilizationMode = .cinematicExtended
                } else {
                    connection.preferredVideoStabilizationMode = .cinematic
                }
            }
        }
    }
}

// MARK: - Main view

private enum ControlTab: String, CaseIterable {
    case iso = "ISO"
    case shutter = "Shutter"
    case wb = "WB"
    case focus = "Focus"
    case ev = "EV"
    case zoom = "Zoom"
}

private enum CaptureMode {
    case photo, video
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var tab: ControlTab = .iso
    @State private var mode: CaptureMode = .photo
    @State private var showLUTs = false
    @State private var showImporter = false
    @State private var focusPoint: CGPoint?
    @State private var showFocusRing = false
    @State private var pinchBase: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.permissionDenied {
                permissionView
            } else if model.isReady {
                cameraView
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.loadSavedLUTs() }
        }
        .sheet(isPresented: $showLUTs) { lutSheet }
        .alert("LUT problem", isPresented: Binding(
            get: { model.lutError != nil },
            set: { if !$0 { model.lutError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lutError = nil }
        } message: {
            Text(model.lutError ?? "")
        }
        .fullScreenCover(item: $model.reviewPhoto) { photo in
            ReviewView(model: model, photo: photo)
        }
    }

    // MARK: - Permission

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("LUT Cam needs the camera to shoot. Turn it on in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Settings") { model.openSettings() }
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .glassCapsule()
        }
    }

    // MARK: - Camera

    private var cameraView: some View {
        GeometryReader { geo in
            ZStack {
                // Preview + tracking boxes scale together for digital zoom (past the lens max),
                // and shift/rotate slightly to cancel phone shake when stabilization is on.
                ZStack {
                    LiveCameraView(model: model)
                        .ignoresSafeArea()

                    if model.faceTracking, let rect = model.faceRect {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.green, lineWidth: 2)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: rect.midX * geo.size.width, y: rect.midY * geo.size.height)
                    }

                    if model.faceTracking, let rect = model.trackRect {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                            .position(x: rect.midX * geo.size.width, y: rect.midY * geo.size.height)
                    }
                }
                .scaleEffect(model.digitalZoomFactor * (model.stabilizationEnabled ? 1.06 : 1))
                .offset(model.stabilizationEnabled ? model.stabOffset : .zero)
                .rotationEffect(.radians(model.stabilizationEnabled ? model.stabRotation : 0))
                .onTapGesture { location in
                    let point = CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height)
                    if model.faceTracking {
                        // Tracking on: the tap selects the point to follow.
                        model.startTracking(at: point)
                    }
                    model.focusAt(point: point)
                    focusPoint = location
                    withAnimation(.easeOut(duration: 0.15)) { showFocusRing = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        withAnimation { showFocusRing = false }
                    }
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if pinchBase == nil { pinchBase = model.zoomFactor }
                            model.setZoom((pinchBase ?? 1) * value)
                        }
                        .onEnded { _ in pinchBase = nil }
                )

                if showFocusRing, let p = focusPoint {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(p)
                        .transition(.opacity)
                }

                VStack {
                    topBar
                    Spacer()
                    if model.savedFlash {
                        Text("Saved to Photos")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.white, in: Capsule())
                            .padding(.bottom, 8)
                    }
                    lutStrip
                    controlDeck
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { showLUTs = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "swatchpalette.fill")
                    Text(model.selectedLUT?.name ?? "No LUT")
                        .lineLimit(1)
                    if model.selectedLUT != nil {
                        Text("\(Int(model.lutStrength * 100))%")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassCapsule()
            }
            Spacer()
            if model.isRecording {
                Text("● \(formatTime(model.recordingSeconds))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassCapsule()
            }
            Text(liveReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCapsule()
        }
    }

    private var liveReadout: String {
        let iso = model.liveISO > 0 ? "ISO \(Int(model.liveISO))" : "ISO —"
        let sh = model.liveShutter > 0 ? formatShutter(model.liveShutter) : "—"
        let zoom = String(format: "%.1f×", model.zoomFactor)
        return "\(iso)  \(sh)  \(Int(model.liveWB))K  \(zoom)"
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - LUT hot-swap strip

    private var lutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                lutChip(title: "None", selected: model.selectedLUT == nil) {
                    model.selectLUT(nil)
                }
                ForEach(model.luts) { lut in
                    lutChip(title: lut.name, selected: model.selectedLUT?.name == lut.name) {
                        model.selectLUT(lut)
                    }
                }
                Button { showLUTs = true } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassCapsule()
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .padding(.bottom, 8)
    }

    private func lutChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? .white : .clear, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    // MARK: - Control deck

    private var controlDeck: some View {
        VStack(spacing: 14) {
            // Tracking + shake stabilization on one row; axis pills on their
            // own row when tracking is on, so nothing ever squeezes or wraps.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.toggleTracking() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.faceTracking ? "viewfinder.circle.fill" : "viewfinder.circle")
                            Text("Track")
                        }
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(model.faceTracking ? .black : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(model.faceTracking ? .white : .clear, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    Button { model.toggleStabilization() } label: {
                        Text("Stab")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(model.stabilizationEnabled ? .black : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(model.stabilizationEnabled ? .white : .clear, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    Spacer()
                }
                if model.faceTracking {
                    HStack(spacing: 8) {
                        ForEach(TrackAxis.allCases, id: \.self) { axis in
                            Button { model.setTrackAxis(axis) } label: {
                                Text(axis.rawValue)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(model.trackAxis == axis ? .black : .white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(model.trackAxis == axis ? .white : .clear, in: Capsule())
                            }
                        }
                        Spacer()
                    }
                }
            }

            // Tabs
            HStack(spacing: 4) {
                ForEach(ControlTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tab == t ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(tab == t ? .white : .clear, in: Capsule())
                    }
                }
            }
            .padding(4)
            .background(.black.opacity(0.35), in: Capsule())

            // Active control
            controlRow

            // Photo / Video switch
            HStack(spacing: 0) {
                modeButton(.photo, "Photo")
                modeButton(.video, "Video")
            }
            .padding(4)
            .background(.black.opacity(0.35), in: Capsule())
            .disabled(model.isRecording)

            // Shutter row
            HStack {
                Button { showLUTs = true } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassCapsule()
                }
                Spacer()
                shutterButton
                Spacer()
                Button(action: allAuto) {
                    Text("All Auto")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 44)
                        .glassCapsule()
                }
            }
        }
        .padding(14)
        .glassPanel()
    }

    private func modeButton(_ m: CaptureMode, _ title: String) -> some View {
        Button {
            mode = m
            // Video caps at the lens max (the file recorder can't do digital zoom);
            // photos go all the way to 1000×.
            model.zoomCap = (m == .video) ? model.deviceMaxZoom : model.maxZoom
            if model.zoomFactor > model.zoomCap { model.setZoom(model.zoomCap) }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(mode == m ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(mode == m ? .white : .clear, in: Capsule())
        }
    }

    private var shutterButton: some View {
        Group {
            if mode == .photo {
                Button { model.capture() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        Circle().fill(.white).frame(width: 58, height: 58)
                    }
                }
            } else if model.isRecording {
                Button { model.stopRecording() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    }
                }
            } else {
                Button { model.startRecording() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        Circle().fill(.red).frame(width: 58, height: 58)
                    }
                }
            }
        }
    }

    private func allAuto() {
        model.setExposureAuto(true)
        model.setWBAuto(true)
        model.setFocusAuto(true)
        model.setExposureBias(0)
        model.setZoom(1)
    }

    @ViewBuilder
    private var controlRow: some View {
        switch tab {
        case .iso:
            ControlRow(
                title: "ISO",
                valueText: model.exposureAuto
                    ? (model.liveISO > 0 ? "Auto · \(Int(model.liveISO))" : "Auto")
                    : "\(Int(model.manualISO))",
                isAuto: model.exposureAuto,
                onAutoToggle: { model.setExposureAuto($0) }
            ) {
                Slider(value: Binding(
                    get: { Double(model.manualISO) },
                    set: { model.setManualISO(Float($0)) }
                ), in: Double(model.isoRange.lowerBound)...Double(model.isoRange.upperBound), step: 1)
                .disabled(model.exposureAuto)
            }
        case .shutter:
            ControlRow(
                title: "Shutter",
                valueText: model.exposureAuto
                    ? (model.liveShutter > 0 ? "Auto · \(formatShutter(model.liveShutter))" : "Auto")
                    : formatShutter(model.manualShutter),
                isAuto: model.exposureAuto,
                onAutoToggle: { model.setExposureAuto($0) }
            ) {
                Slider(value: Binding(
                    get: { logPosition(of: model.manualShutter) },
                    set: { model.setManualShutter(shutterFromLog($0)) }
                ), in: 0...1)
                .disabled(model.exposureAuto)
            }
        case .wb:
            ControlRow(
                title: "White balance",
                valueText: model.wbAuto
                    ? "Auto · \(Int(model.liveWB))K"
                    : "\(Int(model.manualWB))K",
                isAuto: model.wbAuto,
                onAutoToggle: { model.setWBAuto($0) }
            ) {
                Slider(value: Binding(
                    get: { Double(model.manualWB) },
                    set: { model.setManualWB(Float($0)) }
                ), in: Double(model.wbRange.lowerBound)...Double(model.wbRange.upperBound), step: 50)
                .disabled(model.wbAuto)
            }
        case .focus:
            ControlRow(
                title: "Focus",
                valueText: model.focusAuto ? "Auto" : "\(Int(model.manualFocus * 100))%",
                isAuto: model.focusAuto,
                onAutoToggle: { model.setFocusAuto($0) }
            ) {
                Slider(value: Binding(
                    get: { Double(model.manualFocus) },
                    set: { model.setManualFocus(Float($0)) }
                ), in: 0...1)
                .disabled(model.focusAuto)
            }
        case .ev:
            ControlRow(
                title: "Brightness (EV)",
                valueText: formatEV(model.exposureBias),
                isAuto: nil,
                onAutoToggle: nil
            ) {
                Slider(value: Binding(
                    get: { Double(model.exposureBias) },
                    set: { model.setExposureBias(Float($0)) }
                ), in: Double(model.biasRange.lowerBound)...Double(model.biasRange.upperBound), step: 0.1)
                .disabled(!model.exposureAuto)
            }
            if !model.exposureAuto {
                Text("Brightness needs Auto exposure — tap All Auto, or set ISO/Shutter back to Auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .zoom:
            ControlRow(
                title: "Zoom",
                valueText: String(format: "%.1f×", model.zoomFactor),
                isAuto: nil,
                onAutoToggle: nil
            ) {
                Slider(value: Binding(
                    get: { logZoomPosition(model.zoomFactor) },
                    set: { model.setZoom(zoomFromLog($0)) }
                ), in: 0...1)
            }
            Text("To 1000×. Past the lens max it's digital and gets blurry — tap Upscale 4× on the photo after to clean it up. Video caps at the lens max.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Log-scale mapping for the shutter slider (even feel across 1/8000...1s).
    private func logPosition(of seconds: Double) -> Double {
        let lo = log(max(model.shutterRange.lowerBound, 1e-6))
        let hi = log(max(model.shutterRange.upperBound, lo + 0.01))
        let v = log(max(seconds, 1e-6))
        return min(1, max(0, (v - lo) / (hi - lo)))
    }

    private func shutterFromLog(_ t: Double) -> Double {
        let lo = log(max(model.shutterRange.lowerBound, 1e-6))
        let hi = log(max(model.shutterRange.upperBound, lo + 0.01))
        return exp(lo + min(1, max(0, t)) * (hi - lo))
    }

    // Log-scale mapping for the zoom slider (even feel across 1×...max).
    private func logZoomPosition(_ factor: CGFloat) -> Double {
        let hi = log(max(Double(model.maxZoom), 1.01))
        return min(1, max(0, log(max(Double(factor), 1)) / hi))
    }

    private func zoomFromLog(_ t: Double) -> CGFloat {
        let hi = log(max(Double(model.maxZoom), 1.01))
        return CGFloat(exp(min(1, max(0, t)) * hi))
    }

    private func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int(round(1 / seconds)))"
    }

    private func formatEV(_ ev: Float) -> String {
        if ev == 0 { return "0" }
        return String(format: "%+.1f", ev)
    }

    // MARK: - LUT sheet

    private var lutSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Easiest way: put .cube files in the Files app — On My iPhone → LUTCam → LUTs. They show up here when you come back to the app. Files dropped right in the LUTCam folder work too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color(white: 0.12))
                }
                Section {
                    Button {
                        model.selectLUT(nil)
                    } label: {
                        HStack {
                            Text("No LUT").foregroundStyle(.white)
                            Spacer()
                            if model.selectedLUT == nil {
                                Image(systemName: "checkmark").foregroundStyle(.white)
                            }
                        }
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                Section("Your LUTs") {
                    ForEach(model.luts) { lut in
                        Button {
                            model.selectLUT(lut)
                        } label: {
                            HStack {
                                Text(lut.name).foregroundStyle(.white)
                                Spacer()
                                if model.selectedLUT?.name == lut.name {
                                    Image(systemName: "checkmark").foregroundStyle(.white)
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.12))
                        .swipeActions {
                            Button(role: .destructive) { model.deleteLUT(lut) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                if model.selectedLUT != nil {
                    Section("Strength") {
                        HStack {
                            Text("\(Int(model.lutStrength * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 44, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(model.lutStrength) },
                                set: { model.setLUTStrength(Float($0)) }
                            ), in: 0...1)
                        }
                        .listRowBackground(Color(white: 0.12))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("LUTs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showLUTs = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showImporter = true } label: {
                        Label("Import LUT", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importLUT(from: url)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Control row

private struct ControlRow<Content: View>: View {
    let title: String
    let valueText: String
    /// nil = no Auto toggle for this control.
    let isAuto: Bool?
    let onAutoToggle: ((Bool) -> Void)?
    @ViewBuilder let slider: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let isAuto, let onAutoToggle {
                    Button { onAutoToggle(!isAuto) } label: {
                        Text("AUTO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isAuto ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isAuto ? .white : .clear, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                }
            }
            slider.tint(.white)
        }
    }
}

// MARK: - Review

/// Shared cancellation flag for the upscaler (read from a background queue).
private final class CancelBox {
    var cancelled = false
}

private struct ReviewView: View {
    @ObservedObject var model: CameraModel
    let photo: CapturedPhoto
    @State private var strength: Float = 0.7
    @State private var displayed: UIImage?
    @State private var work: DispatchWorkItem?
    @State private var isUpscaling = false
    @State private var upscaleProgress = 0.0
    @State private var upscaleError: String?
    @State private var isUpscaled = false
    @State private var upscaleTask: Task<Void, Never>?
    @State private var cancelBox = CancelBox()
    @State private var upscaledImage: UIImage?
    @State private var beforeUpscale: UIImage?
    @State private var showingBefore = false
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var zoomOffset = CGSize.zero
    @State private var lastOffset = CGSize.zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(zoomOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoom = min(max(lastZoom * $0, 1), 6) }
                            .onEnded { _ in
                                lastZoom = zoom
                                if zoom <= 1.01 {
                                    zoom = 1; lastZoom = 1
                                    zoomOffset = .zero; lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoom > 1 else { return }
                                zoomOffset = CGSize(width: lastOffset.width + value.translation.width,
                                                    height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = zoomOffset }
                    )
                    .onTapGesture(count: 2) {
                        if zoom > 1 {
                            zoom = 1; lastZoom = 1
                            zoomOffset = .zero; lastOffset = .zero
                        } else {
                            zoom = 3; lastZoom = 3
                        }
                    }
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                VStack(spacing: 14) {
                    if model.selectedLUT != nil {
                        HStack {
                            Text("Strength")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Slider(value: $strength, in: 0...1)
                                .tint(.white)
                                .onChange(of: strength) { _ in scheduleRegrade() }
                            Text("\(Int(strength * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    if upscaledImage != nil {
                        Picker("Compare", selection: $showingBefore) {
                            Text("Before").tag(true)
                            Text("After").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: showingBefore) { before in
                            displayed = before ? beforeUpscale : upscaledImage
                        }
                        if let up = upscaledImage, let cg = up.cgImage {
                            Text("Upscaled to \(cg.width) × \(cg.height) — pinch to zoom in and compare.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    if isUpscaling {
                        VStack(spacing: 8) {
                            ProgressView(value: upscaleProgress)
                                .tint(.white)
                            HStack {
                                Text("Upscaling… \(Int(upscaleProgress * 100))%")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                Spacer()
                                Button("Cancel") {
                                    cancelBox.cancelled = true
                                    upscaleTask?.cancel()
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            }
                        }
                    } else {
                        Button { startUpscale() } label: {
                            Label(isUpscaled ? "Upscaled 4×" : "Upscale 4×", systemImage: "wand.and.stars")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .glassCapsule()
                        }
                        .disabled(displayed == nil || isUpscaled)
                    }
                    HStack(spacing: 12) {
                        Button("Retake") {
                            model.reviewPhoto = nil
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .glassCapsule()
                        Button("Save") {
                            if let img = upscaledImage ?? displayed { model.save(image: img) }
                            model.reviewPhoto = nil
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.white, in: Capsule())
                    }
                }
                .padding(14)
                .glassPanel()
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            strength = model.lutStrength
            scheduleRegrade(immediate: true)
        }
        .onDisappear {
            cancelBox.cancelled = true
            upscaleTask?.cancel()
        }
        .alert("Upscale problem", isPresented: Binding(
            get: { upscaleError != nil },
            set: { if !$0 { upscaleError = nil } }
        )) {
            Button("OK", role: .cancel) { upscaleError = nil }
        } message: {
            Text(upscaleError ?? "")
        }
    }

    private func startUpscale() {
        guard let base = displayed, !isUpscaling, !isUpscaled else { return }
        cancelBox.cancelled = false
        beforeUpscale = base
        isUpscaling = true
        upscaleProgress = 0
        let box = cancelBox
        upscaleTask = Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try Upscaler.shared.upscale(base, isCancelled: { box.cancelled }) { p in
                        Task { @MainActor in upscaleProgress = p }
                    }
                }.value
                displayed = out
                upscaledImage = out
                showingBefore = false
                zoom = 1; lastZoom = 1
                zoomOffset = .zero; lastOffset = .zero
                isUpscaled = true
            } catch {
                if (error as? UpscaleError) != .cancelled {
                    upscaleError = (error as? LocalizedError)?.errorDescription ?? "Upscaling failed."
                }
            }
            isUpscaling = false
        }
    }

    private func scheduleRegrade(immediate: Bool = false) {
        isUpscaled = false
        upscaledImage = nil
        beforeUpscale = nil
        showingBefore = false
        zoom = 1; lastZoom = 1
        zoomOffset = .zero; lastOffset = .zero
        work?.cancel()
        let item = DispatchWorkItem {
            let graded = model.graded(photo.original, strength: strength)
            DispatchQueue.main.async { displayed = graded }
        }
        work = item
        if immediate {
            DispatchQueue.global(qos: .userInitiated).async(execute: item)
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08, execute: item)
        }
    }
}
