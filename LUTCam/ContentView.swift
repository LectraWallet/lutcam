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

// MARK: - Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        context.coordinator.layer = layer
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.layer?.frame = view.bounds
        if let connection = context.coordinator.layer?.connection,
           connection.isVideoOrientationSupported,
           let orientation = view.window?.windowScene?.interfaceOrientation {
            switch orientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeRight
            case .landscapeRight: connection.videoOrientation = .landscapeLeft
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var layer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Main view

private enum ControlTab: String, CaseIterable {
    case iso = "ISO"
    case shutter = "Shutter"
    case wb = "WB"
    case focus = "Focus"
    case ev = "EV"
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var tab: ControlTab = .iso
    @State private var showLUTs = false
    @State private var showImporter = false
    @State private var focusPoint: CGPoint?
    @State private var showFocusRing = false

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
        .sheet(isPresented: $showLUTs) { lutSheet }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLUT(from: url)
            }
        }
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
                CameraPreview(session: model.session)
                    .ignoresSafeArea()
                    .onTapGesture { location in
                        let point = CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height)
                        model.focusAt(point: point)
                        focusPoint = location
                        withAnimation(.easeOut(duration: 0.15)) { showFocusRing = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            withAnimation { showFocusRing = false }
                        }
                    }

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
        return "\(iso)  \(sh)  \(Int(model.liveWB))K"
    }

    // MARK: - Control deck

    private var controlDeck: some View {
        VStack(spacing: 14) {
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
                Button { model.capture() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        Circle().fill(.white).frame(width: 58, height: 58)
                    }
                }
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

    private func allAuto() {
        model.setExposureAuto(true)
        model.setWBAuto(true)
        model.setFocusAuto(true)
        model.setExposureBias(0)
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
                    Button {
                        model.selectedLUT = nil
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
                            model.selectedLUT = lut
                        } label: {
                            HStack {
                                Text(lut.name).foregroundStyle(.white)
                                Spacer()
                                if model.selectedLUT?.id == lut.id {
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
                            Slider(value: $model.lutStrength, in: 0...1)
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
                    Button {
                        showLUTs = false
                        showImporter = true
                    } label: {
                        Label("Import LUT", systemImage: "square.and.arrow.down")
                    }
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

private struct ReviewView: View {
    @ObservedObject var model: CameraModel
    let photo: CapturedPhoto
    @State private var strength: Float = 0.7
    @State private var displayed: UIImage?
    @State private var work: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFit()
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
                            if let displayed { model.save(image: displayed) }
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
    }

    private func scheduleRegrade(immediate: Bool = false) {
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
