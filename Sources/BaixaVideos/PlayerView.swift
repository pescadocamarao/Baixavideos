import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
import UIKit

// MARK: - Controlador do player

@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1

    private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.rate = rate
        }
        isPlaying = player.timeControlStatus == .playing
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func seekBy(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if player.timeControlStatus == .playing {
            player.rate = newRate
        }
    }

    func captureFrame() async -> UIImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}

// MARK: - Superfície de vídeo (AVPlayerLayer, base do PiP e do zoom)

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    var onLayer: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        onLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

// MARK: - Volume do sistema (MPVolumeView escondida, truque clássico)

final class VolumeBox {
    static let shared = VolumeBox()
    weak var slider: UISlider?
    private init() {}
}

struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.clipsToBounds = true
        DispatchQueue.main.async { VolumeBox.shared.slider = findSlider(in: view) }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        VolumeBox.shared.slider = findSlider(in: uiView)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider { return slider }
            if let found = findSlider(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Tela do player (estilo VLC)

struct PlayerScreen: View {
    let url: URL
    let title: String
    let isRemote: Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PlayerController

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var fill = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var seekFlash: (text: String, isLeft: Bool)?
    @State private var gestureBadge: (icon: String, text: String)?
    @State private var toast: String?
    @State private var shareItem: ShareSheetItem?
    @State private var playerLayer: AVPlayerLayer?
    @State private var pipController: AVPictureInPictureController?

    @State private var dragMode: DragMode?
    @State private var dragStartTime: Double = 0
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartVolume: Float = 0

    private enum DragMode { case seek, brightness, volume }

    init(url: URL, title: String, isRemote: Bool) {
        self.url = url
        self.title = title
        self.isRemote = isRemote
        _controller = StateObject(wrappedValue: PlayerController(url: url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: controller.player, fill: fill) { layer in
                if playerLayer !== layer {
                    DispatchQueue.main.async { playerLayer = layer }
                }
            }
            .ignoresSafeArea()

            // Zonas de toque: duplo toque nas laterais volta/avança 10s;
            // toque simples alterna os controles.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: geo.size.width * 0.38)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { doubleTapSeek(-10, isLeft: true) }
                        .onTapGesture(count: 1) { toggleControls() }
                    Color.clear
                        .frame(width: geo.size.width * 0.24)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) { toggleControls() }
                    Color.clear
                        .frame(width: geo.size.width * 0.38)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { doubleTapSeek(10, isLeft: false) }
                        .onTapGesture(count: 1) { toggleControls() }
                }
            }
            .ignoresSafeArea()

            if let seekFlash {
                HStack {
                    if seekFlash.isLeft {
                        seekBadge(seekFlash.text, icon: "gobackward.10")
                        Spacer()
                    } else {
                        Spacer()
                        seekBadge(seekFlash.text, icon: "goforward.10")
                    }
                }
                .padding(.horizontal, 28)
                .allowsHitTesting(false)
            }

            if let gestureBadge {
                VStack(spacing: 6) {
                    Image(systemName: gestureBadge.icon)
                        .font(.system(size: 26, weight: .semibold))
                    Text(gestureBadge.text)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                }
                .foregroundColor(.white)
                .padding(16)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }

            if showControls { controlsOverlay }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(.footnote, design: .monospaced).weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.lime)
                        .clipShape(Capsule())
                        .padding(.bottom, 110)
                }
                .allowsHitTesting(false)
            }

            HiddenVolumeView()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .gesture(dragGesture)
        .gesture(magnifyGesture)
        .statusBarHidden(true)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            controller.player.rate = controller.rate
            pokeControls()
        }
        .onDisappear {
            hideTask?.cancel()
            controller.player.pause()
            pipController?.stopPictureInPicture()
        }
        .onChange(of: controller.currentTime) { newValue in
            if !isScrubbing { scrubValue = newValue }
        }
    }

    // MARK: Gestos

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                showControls = true
                if dragMode == nil {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragMode = .seek
                    } else {
                        dragMode = value.startLocation.x < UIScreen.main.bounds.width / 2 ? .brightness : .volume
                    }
                    dragStartTime = controller.currentTime
                    dragStartBrightness = UIScreen.main.brightness
                    dragStartVolume = AVAudioSession.sharedInstance().outputVolume
                }
                let height = max(UIScreen.main.bounds.height, 1)
                switch dragMode {
                case .seek:
                    let delta = Double(value.translation.width) * 0.35
                    let target = max(0, min(dragStartTime + delta, controller.duration))
                    gestureBadge = ("timer", Format.time(target))
                    scrubValue = target
                case .brightness:
                    let newValue = min(1, max(0, dragStartBrightness - CGFloat(value.translation.height) / height))
                    UIScreen.main.brightness = newValue
                    gestureBadge = ("sun.max.fill", "\(Int(newValue * 100))%")
                case .volume:
                    let newValue = min(1, max(0, dragStartVolume - Float(value.translation.height) / Float(height)))
                    VolumeBox.shared.slider?.value = newValue
                    gestureBadge = ("speaker.wave.2.fill", "\(Int(newValue * 100))%")
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .seek {
                    controller.seek(to: scrubValue)
                }
                dragMode = nil
                gestureBadge = nil
                pokeControls()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onEnded { scale in
                if scale > 1.12 { fill = true }
                if scale < 0.88 { fill = false }
            }
    }

    // MARK: Controles

    private var controlsOverlay: some View {
        ZStack {
            VStack {
                HStack(spacing: 14) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .bold))
                    }
                    Text(title)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Button { togglePiP() } label: {
                            Image(systemName: "pip.enter")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    if isRemote, canOpenVLC {
                        Button { openInVLC() } label: {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    Button { shareItem = ShareSheetItem(url: url) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(Format.time(scrubValue))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 52, alignment: .leading)
                        Slider(
                            value: $scrubValue,
                            in: 0...max(controller.duration, 0.1),
                            onEditingChanged: { editing in
                                isScrubbing = editing
                                if !editing { controller.seek(to: scrubValue) }
                                pokeControls()
                            }
                        )
                        .tint(Theme.lime)
                        Text(Format.time(controller.duration))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }

                    HStack {
                        Button { controller.seekBy(-10) } label: {
                            Image(systemName: "gobackward.10").font(.system(size: 20))
                        }
                        Spacer()
                        Button { controller.togglePlay(); pokeControls() } label: {
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                        }
                        Spacer()
                        Button { controller.seekBy(10) } label: {
                            Image(systemName: "goforward.10").font(.system(size: 20))
                        }
                        Spacer()
                        Menu {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                                Button {
                                    controller.setRate(Float(value))
                                } label: {
                                    HStack {
                                        Text(rateLabel(value))
                                        if controller.rate == Float(value) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 20))
                        }
                        Spacer()
                        Button { Task { await capturePrint() } } label: {
                            Image(systemName: "camera.fill").font(.system(size: 19))
                        }
                        Spacer()
                        Button { fill.toggle() } label: {
                            Image(systemName: fill
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 19))
                        }
                    }
                    .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .transition(.opacity)
    }

    private func seekBadge(_ text: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 24, weight: .bold))
            Text(text).font(.system(.caption, design: .monospaced).weight(.bold))
        }
        .foregroundColor(.white)
        .padding(14)
        .background(Color.black.opacity(0.45))
        .clipShape(Circle())
    }

    // MARK: Ações

    private func rateLabel(_ value: Double) -> String {
        let trimmed = value == floor(value) ? String(Int(value)) : String(value)
        return trimmed.replacingOccurrences(of: ".", with: ",") + "x"
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { pokeControls() } else { hideTask?.cancel() }
    }

    private func pokeControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if controller.isPlaying {
                    withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
                }
            }
        }
    }

    private func doubleTapSeek(_ delta: Double, isLeft: Bool) {
        controller.seekBy(delta)
        seekFlash = (delta < 0 ? "-10s" : "+10s", isLeft)
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run { seekFlash = nil }
        }
    }

    private var canOpenVLC: Bool {
        guard let vlcURL = URL(string: "vlc://") else { return false }
        return UIApplication.shared.canOpenURL(vlcURL)
    }

    private func openInVLC() {
        let encoded = url.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        let candidates = [
            "vlc-x-callback://x-callback-url/stream?url=\(encoded)",
            "vlc://\(url.absoluteString)"
        ]
        for candidate in candidates {
            if let vlcURL = URL(string: candidate),
               UIApplication.shared.canOpenURL(vlcURL) {
                UIApplication.shared.open(vlcURL)
                return
            }
        }
        showToast("VLC não encontrado")
    }

    private func togglePiP() {
        if let pipController {
            if pipController.isPictureInPictureActive {
                pipController.stopPictureInPicture()
            } else {
                pipController.startPictureInPicture()
            }
            return
        }
        guard let playerLayer,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            showToast("PiP indisponível")
            return
        }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        pipController = controller
        controller?.startPictureInPicture()
    }

    private func capturePrint() async {
        if let image = await controller.captureFrame() {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            showToast("Print salvo nas Fotos")
        } else {
            showToast("Não consegui capturar o quadro")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run { if toast == message { toast = nil } }
        }
    }
}
