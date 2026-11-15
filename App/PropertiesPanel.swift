import GlimmerCore
import SwiftUI

/// Properties of the active layer: adjustment settings, fill settings, mask.
struct PropertiesPanel: View {
    let session: EditorSession
    let layer: Layer

    static func hasProperties(_ layer: Layer) -> Bool {
        switch layer.content {
        case .adjustment, .fill: true
        default: layer.mask != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch layer.content {
            case .adjustment(let adjustment):
                AdjustmentEditor(adjustment: adjustment,
                                 histogram: session.levelsHistogram?.layerID == layer.id ? session.levelsHistogram?.histogram : nil) { new in
                    session.liveLayer("Edit \(adjustment.kind.title)") { $0.content = .adjustment(new) }
                } commit: {
                    session.commitLiveEdit()
                }
                .task(id: adjustment.kind == .levels ? "\(layer.id)-\(session.document.history.count)-\(session.document.historyIndex)" : "") {
                    if adjustment.kind == .levels { await session.refreshLevelsHistogram(for: layer.id) }
                }
            case .fill(let fill):
                FillEditor(fill: fill, documentSize: session.state.size) { new in
                    session.liveLayer("Edit Fill") { $0.content = .fill(new) }
                } commit: {
                    session.commitLiveEdit()
                }
            default:
                EmptyView()
            }
            if let mask = layer.mask {
                MaskEditor(mask: mask, session: session)
            }
        }
    }
}

// MARK: Shared controls

/// A labelled slider that commits one undo step per drag.
struct ParameterSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let set: (Double) -> Void
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LocalizedStringKey(label)).font(.callout)
                Spacer()
                Text(format(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { set(($0 / step).rounded() * step) }),
                   in: range, onEditingChanged: { if !$0 { commit() } })
                .controlSize(.small)
                // The name and number sit above the slider; VoiceOver gets them on it.
                .accessibilityLabel(Text(LocalizedStringKey(label)))
                .accessibilityValue(Text(verbatim: format(value)))
        }
    }
}

extension SRGBColor {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b) }

    init(_ color: Color, in environment: EnvironmentValues) {
        let c = color.resolve(in: environment)
        self.init(Double(min(max(c.red, 0), 1)), Double(min(max(c.green, 0), 1)), Double(min(max(c.blue, 0), 1)))
    }
}

struct ColorWell: View {
    let label: String
    let color: SRGBColor
    let set: (SRGBColor) -> Void
    @Environment(\.self) private var environment

    var body: some View {
        ColorPicker(LocalizedStringKey(label), selection: Binding(get: { color.swiftUI }, set: { set(SRGBColor($0, in: environment)) }),
                    supportsOpacity: false)
            .font(.callout)
    }
}

// MARK: Adjustments

struct AdjustmentEditor: View {
    let adjustment: Adjustment
    var histogram: Histogram?
    let update: (Adjustment) -> Void
    let commit: () -> Void

    @State private var channel = CurveChannel.rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(LocalizedStringKey(adjustment.kind.title), systemImage: adjustment.kind.symbolName).font(.headline)
                Spacer()
                Button("Reset") {
                    if adjustment.kind == .curves, channel != .rgb || adjustment.curves.count > 1 {
                        // Curves resets the channel on screen, as in the web app.
                        var a = adjustment
                        a.curves[channel] = nil
                        update(a)
                    } else {
                        update(Adjustment(adjustment.kind))
                    }
                    commit()
                }
                .help(adjustment.kind == .curves ? "Reset this channel's curve" : "Reset the adjustment")
                .controlSize(.small)
            }

            switch adjustment.kind {
            case .curves:
                channelPicker
                CurvesEditor(points: adjustment.curve(channel), channel: channel,
                             others: CurveChannel.allCases.filter { $0 != channel && adjustment.curves[$0] != nil }
                                .map { ($0, adjustment.curve($0)) }) { points in
                    var a = adjustment
                    a.curves[channel] = points
                    update(a)
                } commit: { commit() }
                .frame(height: 220)
            case .levels:
                channelPicker
                LevelsHistogramView(bins: histogram?.bins(channel), levels: adjustment.levelsChannel(channel), channel: channel) { ch in
                    var a = adjustment
                    a.levels[channel] = ch
                    update(a)
                } commit: { commit() }
                .frame(height: 150)
                levelsSliders
            case .gradientMap:
                GradientStopsEditor(stops: adjustment.gradient) { stops in
                    var a = adjustment
                    a.gradient = stops
                    update(a)
                } commit: { commit() }
            default:
                EmptyView()
            }

            ForEach(adjustment.kind.sliders, id: \.key) { s in
                ParameterSlider(label: s.label, value: adjustment.number(s.key), range: s.range, step: s.step,
                                format: { s.step >= 1 ? String(Int($0)) : String(format: "%.2f", $0) }) { v in
                    var a = adjustment
                    a.numbers[s.key] = v
                    update(a)
                } commit: { commit() }
            }
            ForEach(adjustment.kind.toggles, id: \.key) { t in
                Toggle(LocalizedStringKey(t.label), isOn: Binding(get: { adjustment.flag(t.key) }, set: { v in
                    var a = adjustment
                    a.flags[t.key] = v
                    update(a)
                    commit()
                }))
            }
            ForEach(adjustment.kind.colors, id: \.key) { c in
                ColorWell(label: c.label, color: adjustment.color(c.key)) { v in
                    var a = adjustment
                    a.colors[c.key] = v
                    update(a)
                }
            }
        }
    }

    private var channelPicker: some View {
        Picker("Channel", selection: $channel) {
            ForEach(CurveChannel.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder private var levelsSliders: some View {
        let l = adjustment.levelsChannel(channel)
        let fields: [(String, WritableKeyPath<LevelsChannel, Double>, ClosedRange<Double>)] = [
            ("Input Black", \.inBlack, 0...1), ("Gamma", \.gamma, 0.1...9.99), ("Input White", \.inWhite, 0...1),
            ("Output Black", \.outBlack, 0...1), ("Output White", \.outWhite, 0...1),
        ]
        ForEach(fields, id: \.0) { field in
            ParameterSlider(label: field.0, value: l[keyPath: field.1], range: field.2) { v in
                var a = adjustment
                var ch = l
                ch[keyPath: field.1] = v
                a.levels[channel] = ch
                update(a)
            } commit: { commit() }
        }
    }
}

/// The input histogram with draggable black, gamma and white input handles
/// (like the web app's Levels editor).
struct LevelsHistogramView: View {
    let bins: [UInt32]?
    let levels: LevelsChannel
    let channel: CurveChannel
    let change: (LevelsChannel) -> Void
    let commit: () -> Void

    @State private var dragging: Handle?

    enum Handle { case black, gamma, white }

    private static let handleHeight = 14.0

    /// Where the gamma handle sits between black and white (web: 0.5^(1/γ)).
    private var gammaPosition: Double {
        levels.inBlack + pow(0.5, 1 / min(max(levels.gamma, 0.1), 9.99)) * (levels.inWhite - levels.inBlack)
    }

    private var tint: Color { Self.channelColor(channel) }

    static func channelColor(_ channel: CurveChannel) -> Color {
        switch channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, graphH = geo.size.height - Self.handleHeight - 4
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                    .frame(height: graphH)
                if let bins {
                    histogramPath(bins, width: w, height: graphH)
                        .fill(tint.opacity(0.55))
                } else {
                    ProgressView().controlSize(.small).frame(width: w, height: graphH)
                }
                handle(.black, at: levels.inBlack, fill: .black, width: w, top: graphH + 4)
                handle(.gamma, at: gammaPosition, fill: .gray, width: w, top: graphH + 4)
                handle(.white, at: levels.inWhite, fill: .white, width: w, top: graphH + 4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = min(max(value.location.x / w, 0), 1)
                    if dragging == nil { dragging = nearest(to: t, startX: value.startLocation.x / w) }
                    drag(dragging!, to: t)
                }
                .onEnded { _ in
                    dragging = nil
                    commit()
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Levels histogram")
        .accessibilityValue("Black \(Int(levels.inBlack * 255)), gamma \(String(format: "%.2f", levels.gamma)), white \(Int(levels.inWhite * 255))")
    }

    private func histogramPath(_ bins: [UInt32], width: Double, height: Double) -> Path {
        // Clip the tallest spikes (e.g. pure black or white) so the rest stays readable.
        let sorted = bins.sorted()
        let cap = Double(max(sorted[min(sorted.count - 1, sorted.count * 99 / 100)], 1)) * 1.15
        return Path { p in
            p.move(to: CGPoint(x: 0, y: height))
            for (i, v) in bins.enumerated() {
                let x = Double(i) / 255 * width
                p.addLine(to: CGPoint(x: x, y: height - min(Double(v) / cap, 1) * (height - 4)))
            }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }

    private func handle(_ h: Handle, at t: Double, fill: Color, width: Double, top: Double) -> some View {
        Path { p in
            let x = t * width, s = Self.handleHeight
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x + s * 0.55, y: top + s))
            p.addLine(to: CGPoint(x: x - s * 0.55, y: top + s))
            p.closeSubpath()
        }
        .fill(fill)
        .overlay(Path { p in
            let x = t * width, s = Self.handleHeight
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x + s * 0.55, y: top + s))
            p.addLine(to: CGPoint(x: x - s * 0.55, y: top + s))
            p.closeSubpath()
        }.stroke(.secondary, lineWidth: 0.75))
    }

    private func nearest(to t: Double, startX: Double) -> Handle {
        let candidates: [(Handle, Double)] = [(.black, levels.inBlack), (.gamma, gammaPosition), (.white, levels.inWhite)]
        return candidates.min { abs($0.1 - startX) < abs($1.1 - startX) }!.0
    }

    private func drag(_ h: Handle, to t: Double) {
        var l = levels
        switch h {
        case .black: l.inBlack = min(t, l.inWhite - 0.01)
        case .white: l.inWhite = max(t, l.inBlack + 0.01)
        case .gamma:
            let span = max(l.inWhite - l.inBlack, 0.001)
            let mid = min(max((t - l.inBlack) / span, 0.001), 0.999)
            l.gamma = min(max(log(0.5) / log(mid), 0.1), 9.99)
        }
        change(l)
    }
}

/// Drag points to shape the curve; click to add a point; drag a point off the
/// graph to remove it.
struct CurvesEditor: View {
    let points: [CurvePoint]
    let channel: CurveChannel
    /// The other channels' curves, drawn faintly behind this one.
    var others: [(CurveChannel, [CurvePoint])] = []
    let update: ([CurvePoint]) -> Void
    let commit: () -> Void

    @State private var dragging: Int?
    /// The point the keyboard moves (arrows; ⌥← ⌥→ pick another).
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var tint: Color { Self.channelColor(channel) }

    static func channelColor(_ channel: CurveChannel) -> Color {
        switch channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    /// Moves the selected point by whole levels (0…255), keeping it between its neighbours.
    private func nudge(dx: Double, dy: Double) {
        var pts = points.sorted { $0.x < $1.x }
        guard pts.indices.contains(selected) else { return }
        let i = selected
        let lo = i > 0 ? pts[i - 1].x + 0.01 : 0
        let hi = i < pts.count - 1 ? pts[i + 1].x - 0.01 : 1
        let isEndpoint = i == 0 || i == pts.count - 1
        let x = isEndpoint ? pts[i].x : min(max(pts[i].x + dx / 255, lo), hi)
        pts[i] = CurvePoint(x, min(max(pts[i].y + dy / 255, 0), 1))
        update(pts)
        commit()
    }

    private var pointsDescription: String {
        points.sorted { $0.x < $1.x }.enumerated().map { i, p in
            "\(i == selected ? "▸ " : "")\(Int((p.x * 255).rounded())) → \(Int((p.y * 255).rounded()))"
        }.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(rect), with: .color(Color(nsColor: .textBackgroundColor)))
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(diagonal, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

                for (other, otherPoints) in others {
                    var faint = Path()
                    for i in 0...64 {
                        let t = Double(i) / 64
                        let p = CGPoint(x: size.width * t, y: size.height * (1 - CurveMath.evaluate(otherPoints, at: t)))
                        i == 0 ? faint.move(to: p) : faint.addLine(to: p)
                    }
                    ctx.stroke(faint, with: .color(Self.channelColor(other).opacity(0.35)), lineWidth: 1)
                }
                var curve = Path()
                for i in 0...128 {
                    let t = Double(i) / 128
                    let p = CGPoint(x: size.width * t, y: size.height * (1 - CurveMath.evaluate(points, at: t)))
                    i == 0 ? curve.move(to: p) : curve.addLine(to: p)
                }
                ctx.stroke(curve, with: .color(tint), lineWidth: 1.5)
                for (i, p) in points.sorted(by: { $0.x < $1.x }).enumerated() {
                    let c = CGPoint(x: size.width * p.x, y: size.height * (1 - p.y))
                    let r: CGFloat = dragging == i ? 5 : 4
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(tint))
                    if focused, i == selected {
                        // The keyboard's point gets a ring.
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(.accentColor), lineWidth: 2)
                    }
                }
                ctx.stroke(Path(rect), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag(at: $0.location, size: size, start: $0.startLocation) }
                .onEnded { _ in
                    dragging = nil
                    commit()
                })
        }
        // Keyboard: arrows move the selected point by one level (⇧ by ten), ⌥← ⌥→ pick a point.
        .focusable()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            let step: Double = press.modifiers.contains(.shift) ? 10 : 1
            let count = points.count
            switch press.key {
            case .leftArrow where press.modifiers.contains(.option): selected = max(selected - 1, 0)
            case .rightArrow where press.modifiers.contains(.option): selected = min(selected + 1, count - 1)
            case .leftArrow: nudge(dx: -step, dy: 0)
            case .rightArrow: nudge(dx: step, dy: 0)
            case .upArrow: nudge(dx: 0, dy: step)
            case .downArrow: nudge(dx: 0, dy: -step)
            default: return .ignored
            }
            return .handled
        }
        .accessibilityLabel("\(channel.title) curve")
        .accessibilityValue(pointsDescription)
        .accessibilityHint("Arrow keys move the marked point; Option-Left and Option-Right pick another.")
        .accessibilityAdjustableAction { direction in
            nudge(dx: 0, dy: direction == .increment ? 5 : -5)
        }
        .accessibilityAction(named: "Next Point") { selected = min(selected + 1, points.count - 1) }
        .accessibilityAction(named: "Previous Point") { selected = max(selected - 1, 0) }
    }

    private func drag(at location: CGPoint, size: CGSize, start: CGPoint) {
        var pts = points.sorted { $0.x < $1.x }
        let value = CurvePoint(min(max(location.x / size.width, 0), 1), 1 - location.y / size.height)
        if dragging == nil {
            let s = CurvePoint(start.x / size.width, 1 - start.y / size.height)
            if let near = pts.indices.min(by: { dist(pts[$0], s, size) < dist(pts[$1], s, size) }),
               dist(pts[near], s, size) < 10 {
                dragging = near
            } else {
                pts.append(CurvePoint(min(max(s.x, 0), 1), min(max(s.y, 0), 1)))
                pts.sort { $0.x < $1.x }
                dragging = pts.firstIndex { $0.x == min(max(s.x, 0), 1) }
            }
        }
        guard let i = dragging, pts.indices.contains(i) else { return }
        let isEndpoint = i == 0 || i == pts.count - 1
        let x = location.x / size.width
        if !isEndpoint, value.y < -0.15 || value.y > 1.15 || x < -0.15 || x > 1.15 {
            pts.remove(at: i)
            dragging = nil
            update(pts)
            return
        }
        let lo = i > 0 ? pts[i - 1].x + 0.01 : 0
        let hi = i < pts.count - 1 ? pts[i + 1].x - 0.01 : 1
        pts[i] = CurvePoint(min(max(value.x, lo), hi), min(max(value.y, 0), 1))
        update(pts)
    }

    private func dist(_ p: CurvePoint, _ q: CurvePoint, _ size: CGSize) -> CGFloat {
        hypot((p.x - q.x) * size.width, (p.y - q.y) * size.height)
    }
}

struct GradientStopsEditor: View {
    let stops: [GradientStop]
    let update: ([GradientStop]) -> Void
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(stops: stops.sorted { $0.position < $1.position }.map {
                    .init(color: $0.color.swiftUI.opacity($0.opacity), location: $0.position)
                }, startPoint: .leading, endPoint: .trailing))
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                HStack {
                    ColorWell(label: "", color: stop.color) { c in
                        var s = stops
                        s[i].color = c
                        update(s)
                    }
                    .labelsHidden()
                    Slider(value: Binding(get: { stop.position }, set: { v in
                        var s = stops
                        s[i].position = v
                        update(s)
                    }), in: 0...1, onEditingChanged: { if !$0 { commit() } })
                    .controlSize(.small)
                    .accessibilityLabel("Stop position")
                    .accessibilityValue("\(Int((stop.position * 100).rounded())) %")
                    Button {
                        var s = stops
                        s.remove(at: i)
                        update(s)
                        commit()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(stops.count <= 2)
                    .accessibilityLabel("Remove stop")
                }
            }
            Button("Add Stop", systemImage: "plus") {
                let (c, o) = GradientStop.sample(stops, at: 0.5)
                update(stops + [GradientStop(0.5, c, opacity: o)])
                commit()
            }
            .controlSize(.small)
        }
    }
}

// MARK: Fill

struct FillEditor: View {
    let fill: Fill
    let documentSize: SIMD2<Double>
    let update: (Fill) -> Void
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fill.title).font(.headline)
            switch fill {
            case .solid(let c):
                ColorWell(label: "Color", color: c) { update(.solid($0)) }
            case .gradient(let g):
                Picker("Style", selection: Binding(get: { g.style }, set: { v in
                    var n = g
                    n.style = v
                    update(.gradient(n))
                    commit()
                })) {
                    ForEach(GradientStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)
                GradientStopsEditor(stops: g.stops) { stops in
                    var n = g
                    n.stops = stops
                    update(.gradient(n))
                } commit: { commit() }
                ParameterSlider(label: "Angle", value: angle(g), range: -180...180, step: 1,
                                format: { "\(Int($0))°" }) { a in
                    update(.gradient(withAngle(g, a)))
                } commit: { commit() }
                Toggle("Reverse", isOn: Binding(get: { g.reverse }, set: { v in
                    var n = g
                    n.reverse = v
                    update(.gradient(n))
                    commit()
                }))
            case .pattern(let p):
                Picker("Pattern", selection: Binding(get: { p.kind }, set: { v in
                    var n = p
                    n.kind = v
                    update(.pattern(n))
                    commit()
                })) {
                    ForEach(PatternKind.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                ParameterSlider(label: "Scale", value: p.scale, range: 2...512, step: 1, format: { "\(Int($0)) px" }) { v in
                    var n = p
                    n.scale = v
                    update(.pattern(n))
                } commit: { commit() }
                ColorWell(label: "Foreground", color: p.foreground) { c in
                    var n = p
                    n.foreground = c
                    update(.pattern(n))
                }
                ColorWell(label: "Background", color: p.background) { c in
                    var n = p
                    n.background = c
                    update(.pattern(n))
                }
            }
        }
    }

    private func angle(_ g: GradientFill) -> Double {
        let d = g.end - g.start
        return (atan2(-d.y, d.x) * 180 / .pi).rounded()
    }

    /// Re-aims the gradient through the document centre at `degrees`.
    private func withAngle(_ g: GradientFill, _ degrees: Double) -> GradientFill {
        var n = g
        let r = degrees * .pi / 180
        let dir = SIMD2(cos(r), -sin(r))
        let c = documentSize / 2
        let half = (abs(dir.x) * documentSize.x + abs(dir.y) * documentSize.y) / 2
        n.start = c - dir * half
        n.end = c + dir * half
        return n
    }
}

// MARK: Mask

private struct MaskEditor: View {
    let mask: LayerMask
    let session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Layer Mask", systemImage: "rectangle.dashed").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { mask.isEnabled }, set: { _ in session.perform(.toggleMask) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Enable or disable the mask")
            }
            ParameterSlider(label: "Density", value: mask.density * 100, range: 0...100, step: 1,
                            format: { "\(Int($0)) %" }) { v in
                session.liveLayer("Mask Density") { $0.mask?.density = v / 100 }
            } commit: { session.commitLiveEdit() }
            ParameterSlider(label: "Feather", value: mask.feather, range: 0...250, step: 0.5,
                            format: { String(format: "%.1f px", $0) }) { v in
                session.liveLayer("Mask Feather") { $0.mask?.feather = v }
            } commit: { session.commitLiveEdit() }
            HStack {
                Button("Invert Default") {
                    session.liveLayer("Invert Mask") { layer in
                        if let v = layer.mask?.defaultValue { layer.mask?.defaultValue = 1 - v }
                    }
                    session.commitLiveEdit()
                }
                .help("Swap Reveal All and Hide All for unpainted areas")
                Spacer()
                Button("Delete Mask", role: .destructive) { session.perform(.deleteMask) }
            }
            .controlSize(.small)
        }
    }
}
