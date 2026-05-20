import AppKit
import Foundation
import QuartzCore

enum ClaudeTaskState: String {
    case idle
    case running
    case needsConfirmation

    var displayColor: NSColor {
        switch self {
        case .idle:
            return NSColor.systemGreen
        case .running:
            return NSColor.systemYellow
        case .needsConfirmation:
            return NSColor.systemRed
        }
    }

    var title: String {
        switch self {
        case .idle:
            return "空闲(绿)"
        case .running:
            return "执行中(黄)"
        case .needsConfirmation:
            return "需确认(红)"
        }
    }

    static func from(rawValue: String) -> ClaudeTaskState {
        switch rawValue.lowercased() {
        case "running":
            return .running
        case "needs_confirmation", "needsconfirmation", "confirm", "approval":
            return .needsConfirmation
        default:
            return .idle
        }
    }
}

struct StatusPayload: Codable {
    let state: String
    let updatedAt: String?
}

final class StatusStore {
    private let url: URL
    private var lastState: String = ""

    init(path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        self.url = URL(fileURLWithPath: expandedPath)
    }

    func readState() -> ClaudeTaskState? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(StatusPayload.self, from: data)
            guard payload.state != lastState else { return nil }
            lastState = payload.state
            return ClaudeTaskState.from(rawValue: payload.state)
        } catch {
            return nil
        }
    }
}

// MARK: - Slider Menu Item

final class SliderMenuItemView: NSView {
    let label: NSTextField
    let slider: NSSlider
    private let labelPrefix: String
    private let suffix: String

    init(title: String, minValue: Double, maxValue: Double, currentValue: Double, suffix: String = "%", target: AnyObject?, action: Selector?) {
        self.labelPrefix = title
        self.suffix = suffix
        label = NSTextField(labelWithString: "\(title): \(Int(currentValue))\(suffix)")
        label.font = NSFont.menuFont(ofSize: 13)
        slider = NSSlider(value: currentValue, minValue: minValue, maxValue: maxValue, target: target, action: action)
        slider.isContinuous = true
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        addSubview(label)
        addSubview(slider)
        label.frame = NSRect(x: 16, y: 20, width: 190, height: 16)
        slider.frame = NSRect(x: 16, y: 2, width: 190, height: 18)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLabel() {
        label.stringValue = "\(labelPrefix): \(Int(slider.doubleValue))\(suffix)"
    }
}

// MARK: - Glow View

final class GlowOverlayView: NSView {
    var color: NSColor = .systemGreen {
        didSet {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            targetR = rgb.redComponent
            targetG = rgb.greenComponent
            targetB = rgb.blueComponent
            targetA = rgb.alphaComponent
            isTransitioning = true
            setFPS(30)
        }
    }

    var brightnessPercent: CGFloat = 70
    var waveWidthPercent: CGFloat = 50
    var visible: Bool = true {
        didSet {
            layer?.isHidden = !visible
            if visible && timer == nil { startAnimation() }
            if !visible { stopAnimation() }
        }
    }

    private let bandCount = 10
    private var gradientLayers: [CAGradientLayer] = []
    private var maskLayers: [CAShapeLayer] = []

    private var timer: Timer?
    private var time: CGFloat = 0
    private var currentR: CGFloat = 0, currentG: CGFloat = 0, currentB: CGFloat = 0, currentA: CGFloat = 1
    private var targetR: CGFloat = 0, targetG: CGFloat = 0, targetB: CGFloat = 0, targetA: CGFloat = 1
    private var isTransitioning: Bool = false
    private var currentFPS: Double = 15

    private let samplesPerSide = 32
    private let gradientStops = 128

    private var cachedLocations: [NSNumber] = []
    private var colorBuffers: [[CGColor]] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
        initColorComponents(color)
        startAnimation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
        initColorComponents(color)
        startAnimation()
    }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimation()
        } else if timer == nil && visible {
            startAnimation()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        for gl in gradientLayers { gl.frame = b }
        updateAll()
        CATransaction.commit()
    }

    private func initColorComponents(_ c: NSColor) {
        let rgb = c.usingColorSpace(.deviceRGB) ?? c
        targetR = rgb.redComponent
        targetG = rgb.greenComponent
        targetB = rgb.blueComponent
        targetA = rgb.alphaComponent
        currentR = targetR; currentG = targetG; currentB = targetB; currentA = targetA
        updateCachedHSB()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for _ in 0..<bandCount {
            let gl = CAGradientLayer()
            gl.type = .conic
            gl.startPoint = CGPoint(x: 0.5, y: 0.5)
            gl.endPoint = CGPoint(x: 0.5, y: 0)
            gl.contentsScale = scale
            layer?.addSublayer(gl)
            gradientLayers.append(gl)

            let ml = CAShapeLayer()
            ml.fillColor = NSColor.white.cgColor
            ml.fillRule = .evenOdd
            gl.mask = ml
            maskLayers.append(ml)
        }

        cachedLocations = (0..<gradientStops).map {
            NSNumber(value: Float($0) / Float(gradientStops))
        }
        let placeholder = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorBuffers = Array(repeating: Array(repeating: placeholder, count: gradientStops), count: bandCount)

        updateAll()
    }

    // MARK: - Wave ring path

    private func waveContour(inset: CGFloat, amplitude: CGFloat, into path: CGMutablePath) {
        let w = bounds.width
        let h = bounds.height
        let n = samplesPerSide
        let invN = 1.0 / CGFloat(n)

        let t07 = time * 0.7, t05 = time * 0.5
        let t06 = time * 0.6, t045 = time * 0.45
        let t08 = time * 0.8, t055 = time * 0.55
        let t065 = time * 0.65

        let amp04 = amplitude * 0.4

        // Top side (left → right)
        for i in 0...n {
            let f = CGFloat(i) * invN
            let x = f * w
            let wave = amplitude * sin(f * .pi * 4.0 + t07)
                + amp04 * sin(f * .pi * 6.5 - t05)
            let pt = CGPoint(x: x, y: max(0, inset + wave))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        // Top-right corner: route inward to avoid diagonal seam
        path.addLine(to: CGPoint(x: w - inset, y: inset))

        // Right side (top → bottom)
        for i in 0...n {
            let f = CGFloat(i) * invN
            let y = f * h
            let wave = amplitude * sin(f * .pi * 4.0 + t06 + 1.5)
                + amp04 * sin(f * .pi * 6.5 - t045 + 2.0)
            path.addLine(to: CGPoint(x: min(w, w - inset - wave), y: y))
        }
        // Bottom-right corner
        path.addLine(to: CGPoint(x: w - inset, y: h - inset))

        // Bottom side (right → left)
        for i in 0...n {
            let f = CGFloat(i) * invN
            let x = w - f * w
            let wave = amplitude * sin(f * .pi * 4.0 + t08 + 3.0)
                + amp04 * sin(f * .pi * 6.5 - t055 + 4.0)
            path.addLine(to: CGPoint(x: x, y: min(h, h - inset - wave)))
        }
        // Bottom-left corner
        path.addLine(to: CGPoint(x: inset, y: h - inset))

        // Left side (bottom → top)
        for i in 0...n {
            let f = CGFloat(i) * invN
            let y = h - f * h
            let wave = amplitude * sin(f * .pi * 4.0 + t065 + 5.0)
                + amp04 * sin(f * .pi * 6.5 - t05 + 6.0)
            path.addLine(to: CGPoint(x: max(0, inset + wave), y: y))
        }
        // Top-left corner
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.closeSubpath()
    }

    private func buildRingPath(innerInset: CGFloat, innerAmp: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        waveContour(inset: innerInset, amplitude: innerAmp, into: path)
        return path
    }

    // MARK: - Gradient colors with bright spots

    private var cachedHue: CGFloat = 0
    private var cachedSat: CGFloat = 0
    private var cachedBri: CGFloat = 0

    private func updateCachedHSB() {
        let maxC = max(currentR, currentG, currentB)
        let minC = min(currentR, currentG, currentB)
        let delta = maxC - minC
        cachedBri = maxC
        cachedSat = maxC > 0 ? delta / maxC : 0
        if delta < 0.0001 {
            cachedHue = 0
        } else if maxC == currentR {
            cachedHue = fmod((currentG - currentB) / delta, 6.0) / 6.0
        } else if maxC == currentG {
            cachedHue = ((currentB - currentR) / delta + 2.0) / 6.0
        } else {
            cachedHue = ((currentR - currentG) / delta + 4.0) / 6.0
        }
        if cachedHue < 0 { cachedHue += 1.0 }
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func hsbToRGB(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s < 0.0001 { return (v, v, v) }
        let hh = h * 6.0
        let sector = Int(hh) % 6
        let f = hh - CGFloat(sector)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private func fillGradientColors(bandIndex: Int, maxAlpha: CGFloat) {
        let baseHue = cachedHue
        let baseSat = cachedSat
        let baseBri = cachedBri
        let phaseOffset = CGFloat(bandIndex) * 0.8

        let spot1Pos = fmod(time * 0.03, 1.0)
        let spot2Pos = fmod(time * 0.025 + 0.37, 1.0)
        let spot3Pos = fmod(time * 0.02 + 0.7, 1.0)
        let invStops = 1.0 / CGFloat(gradientStops)
        let timeTerm = time * 0.3 + phaseOffset

        for i in 0..<gradientStops {
            let t = CGFloat(i) * invStops

            let d1 = { let d = abs(t - spot1Pos); return min(d, 1.0 - d) }()
            let d2 = { let d = abs(t - spot2Pos); return min(d, 1.0 - d) }()
            let d3 = { let d = abs(t - spot3Pos); return min(d, 1.0 - d) }()

            let g1 = exp(-d1 * d1 / 0.008)
            let g2 = exp(-d2 * d2 / 0.012)
            let g3 = exp(-d3 * d3 / 0.006)

            let spotIntensity = min(1.0, g1 + g2 * 0.8 + g3 * 0.6)
            let intensity = 0.15 + spotIntensity * 0.85

            let hueShift = g1 * 0.06 - g2 * 0.04 + g3 * 0.08
                + sin(t * .pi * 2 + timeTerm) * 0.03
            var hue = baseHue + hueShift
            if hue < 0 { hue += 1.0 }
            if hue > 1 { hue -= 1.0 }

            let sat = min(1.0, baseSat * (0.7 + spotIntensity * 0.5))
            let bri = min(1.0, baseBri * (0.8 + intensity * 0.5))
            let alpha = intensity * maxAlpha

            let (r, g, b) = hsbToRGB(hue, sat, bri)
            colorBuffers[bandIndex][i] = CGColor(colorSpace: Self.colorSpace, components: [r, g, b, alpha])!
        }
    }

    // MARK: - Update

    private func updateAll() {
        let wf = waveWidthPercent / 100.0
        let maxInset = 10.0 + wf * 70.0
        let maxAmp = 3.0 + wf * 17.0
        let alphaMul = 0.3 + brightnessPercent / 100.0 * 1.2
        let invBands = 1.0 / CGFloat(bandCount)
        let shadowCGColor = CGColor(red: currentR, green: currentG, blue: currentB, alpha: 1)

        for idx in 0..<bandCount {
            let t0 = CGFloat(idx) * invBands
            let t1 = CGFloat(idx + 1) * invBands

            let innerInset = 1.0 + t1 * maxInset
            let innerAmp = 1.0 + t1 * maxAmp

            let tMid = (t0 + t1) * 0.5
            let falloff = 1.0 - tMid
            let bandAlpha = falloff * falloff * alphaMul

            let path = buildRingPath(innerInset: innerInset, innerAmp: innerAmp)
            maskLayers[idx].path = path

            let breathe: CGFloat = 0.85 + 0.15 * sin(time * 0.5 + CGFloat(idx) * 0.2)
            fillGradientColors(bandIndex: idx, maxAlpha: bandAlpha * breathe)
            gradientLayers[idx].colors = colorBuffers[idx]
            gradientLayers[idx].locations = cachedLocations

            if idx == 0 {
                gradientLayers[0].shadowColor = shadowCGColor
                gradientLayers[0].shadowOpacity = Float(0.3 * breathe * alphaMul)
                gradientLayers[0].shadowRadius = 10
                gradientLayers[0].shadowOffset = .zero
            }
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }
        setFPS(currentFPS)
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func setFPS(_ fps: Double) {
        guard fps != currentFPS || timer == nil else { return }
        currentFPS = fps
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.current.add(timer, forMode: .common) }
    }

    private func tick() {
        time += 1.0 / currentFPS

        let lerpT: CGFloat = 0.06
        currentR += (targetR - currentR) * lerpT
        currentG += (targetG - currentG) * lerpT
        currentB += (targetB - currentB) * lerpT
        currentA += (targetA - currentA) * lerpT
        updateCachedHSB()

        if isTransitioning {
            let dr = abs(targetR - currentR)
            let dg = abs(targetG - currentG)
            let db = abs(targetB - currentB)
            if dr < 0.001 && dg < 0.001 && db < 0.001 {
                currentR = targetR; currentG = targetG; currentB = targetB
                isTransitioning = false
                setFPS(15)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateAll()
        CATransaction.commit()
    }
}

// MARK: - Window Controller

final class OverlayWindowController {
    private var windows: [NSWindow] = []
    private var color: NSColor = .systemGreen
    private var brightnessPercent: CGFloat = 70
    private var waveWidthPercent: CGFloat = 50
    private var visible: Bool = true

    init() {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setColor(_ color: NSColor) {
        self.color = color
        for window in windows {
            (window.contentView as? GlowOverlayView)?.color = color
        }
    }

    func setBrightness(_ percent: CGFloat) {
        self.brightnessPercent = percent
        for window in windows {
            (window.contentView as? GlowOverlayView)?.brightnessPercent = percent
        }
    }

    func setWaveWidth(_ percent: CGFloat) {
        self.waveWidthPercent = percent
        for window in windows {
            (window.contentView as? GlowOverlayView)?.waveWidthPercent = percent
        }
    }

    func setVisible(_ v: Bool) {
        self.visible = v
        for window in windows {
            (window.contentView as? GlowOverlayView)?.visible = v
        }
    }

    @objc private func handleScreenChange() { rebuildWindows() }

    private func rebuildWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = GlowOverlayView(frame: window.contentView?.bounds ?? screen.frame)
            view.autoresizingMask = [.width, .height]
            view.color = color
            view.brightnessPercent = brightnessPercent
            view.waveWidthPercent = waveWidthPercent
            view.visible = visible
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
    }
}

// MARK: - Poller

final class StatusPoller {
    private let store: StatusStore
    private let onStateChanged: (ClaudeTaskState) -> Void
    private var timer: Timer?
    private var debounceTimer: Timer?
    private(set) var currentState: ClaudeTaskState = .idle
    private var pendingState: ClaudeTaskState?

    private let confirmationDebounce: TimeInterval = 0.4

    init(store: StatusStore, onStateChanged: @escaping (ClaudeTaskState) -> Void) {
        self.store = store
        self.onStateChanged = onStateChanged
    }

    func start() {
        onStateChanged(currentState)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil; debounceTimer?.invalidate() }

    private func tick() {
        guard let latest = store.readState(), latest != currentState || latest != pendingState else { return }

        if latest == .needsConfirmation && currentState != .needsConfirmation {
            pendingState = latest
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: confirmationDebounce, repeats: false) { [weak self] _ in
                guard let self, self.pendingState == .needsConfirmation else { return }
                self.currentState = .needsConfirmation
                self.onStateChanged(.needsConfirmation)
            }
        } else if latest != .needsConfirmation {
            debounceTimer?.invalidate()
            pendingState = nil
            if latest != currentState {
                currentState = latest
                onStateChanged(latest)
            }
        }
    }
}

// MARK: - App Delegate

final class ClaudeStatusGlowAppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayWindowController?
    private var poller: StatusPoller?
    private var statusItem: NSStatusItem?

    private var currentBrightness: CGFloat = 70
    private var currentWaveWidth: CGFloat = 50
    private var idleGlowEnabled: Bool = true

    private var brightnessSliderView: SliderMenuItemView?
    private var waveWidthSliderView: SliderMenuItemView?
    private var idleGlowItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let statePath = ProcessInfo.processInfo.environment["CLAUDE_STATUS_FILE"]
            ?? "~/.claudecode/status.json"

        let store = StatusStore(path: statePath)
        let overlay = OverlayWindowController()
        overlayController = overlay

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Claude光圈"
        let menu = NSMenu()

        // Status line
        menu.addItem(NSMenuItem(title: "状态: 空闲(绿)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        // Brightness slider
        let briView = SliderMenuItemView(
            title: "亮度", minValue: 10, maxValue: 100,
            currentValue: Double(currentBrightness), target: self, action: #selector(brightnessChanged(_:)))
        let briItem = NSMenuItem()
        briItem.view = briView
        menu.addItem(briItem)
        brightnessSliderView = briView
        menu.addItem(.separator())

        // Wave width slider
        let waveView = SliderMenuItemView(
            title: "波浪宽度", minValue: 10, maxValue: 100,
            currentValue: Double(currentWaveWidth), target: self, action: #selector(waveWidthChanged(_:)))
        let waveItem = NSMenuItem()
        waveItem.view = waveView
        menu.addItem(waveItem)
        waveWidthSliderView = waveView
        menu.addItem(.separator())

        // Idle glow toggle
        let idleMi = NSMenuItem(title: "空闲时显示", action: #selector(toggleIdleGlow(_:)), keyEquivalent: "")
        idleMi.target = self
        idleMi.state = idleGlowEnabled ? .on : .off
        menu.addItem(idleMi)
        idleGlowItem = idleMi

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        poller = StatusPoller(store: store) { [weak self] state in
            guard let self else { return }
            overlay.setColor(state.displayColor)
            self.statusItem?.menu?.item(at: 0)?.title = "状态: \(state.title)"
            self.updateVisibility(state: state)
        }
        poller?.start()
    }

    private func updateVisibility(state: ClaudeTaskState) {
        if state == .idle && !idleGlowEnabled {
            overlayController?.setVisible(false)
        } else {
            overlayController?.setVisible(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { poller?.stop() }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        currentBrightness = val
        overlayController?.setBrightness(val)
        brightnessSliderView?.updateLabel()
    }

    @objc private func waveWidthChanged(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        currentWaveWidth = val
        overlayController?.setWaveWidth(val)
        waveWidthSliderView?.updateLabel()
    }

    @objc private func toggleIdleGlow(_ sender: NSMenuItem) {
        idleGlowEnabled = !idleGlowEnabled
        sender.state = idleGlowEnabled ? .on : .off
        if let state = poller?.currentState {
            updateVisibility(state: state)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

@main
struct ClaudeStatusGlowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ClaudeStatusGlowAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
