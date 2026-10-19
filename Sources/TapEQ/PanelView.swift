import AppKit
import CoreAudio
import SwiftUI
import TapEQCore

/// Monochrome, terminal-style look: black, one monospaced face, square 1px borders.
enum Style {
    static let background = Color.black
    static let text = Color.white
    static let secondary = Color(white: 0.4)
    static let border = Color(white: 0.2)
    static let faint = Color(white: 0.13)

    /// JetBrains Mono when installed, otherwise the system monospaced face (SF Mono).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let family = monoFamily {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    private static let monoFamily: String? = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["JetBrains Mono", "JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font"].first(where: installed.contains)
    }()
}

/// The window shown from the menu bar icon.
struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Box("Spectrum") {
                AsciiSpectrum(levels: model.spectrum, isActive: model.isOn)
            }
            Box("Preset", detail: model.presetName == nil ? "custom" : nil) {
                presets
            }
            Box("Effects") {
                effects
            }
            Box("Equalizer", trailing: AnyView(TextButton("Reset", action: model.resetEQ))) {
                EQCurveEditor(parameters: $model.parameters)
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(Style.background)
        .foregroundStyle(Style.text)
        .environment(\.colorScheme, .dark)
        .onAppear { model.isPanelVisible = true }
        .onDisappear { model.isPanelVisible = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TAPEQ")
                    .font(Style.mono(16))
                    .tracking(2)
                statusLine
                    .font(Style.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            PowerButton(status: model.status, action: model.togglePower)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .off:
            Text("off · apps play normally").foregroundStyle(Style.secondary)
        case .starting:
            Text("starting · allow audio recording if asked").foregroundStyle(Style.secondary)
        case let .running(name, sampleRate):
            Text("on · \(name.lowercased()) · \(sampleRate / 1000, format: .number.precision(.fractionLength(0...1)))khz")
                .foregroundStyle(Style.secondary)
        case let .failed(message):
            Text("error · \(message)").foregroundStyle(Style.text).help(message)
        }
    }

    // MARK: Sections

    private var presets: some View {
        HStack(spacing: 4) {
            ForEach(SoundPreset.builtIn) { preset in
                SelectableCell(title: preset.name, isSelected: model.presetName == preset.name) {
                    model.apply(preset)
                }
            }
        }
    }

    private var effects: some View {
        VStack(spacing: 8) {
            ForEach(Effect.allCases) { effect in
                EffectSlider(title: effect.title, value: Binding(
                    get: { model.parameters[effect] },
                    set: { model.parameters[effect] = $0 }
                ))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsciiCheckbox(
                title: "Launch at login",
                isOn: Binding(get: { model.loginItem != .off }, set: { model.setLaunchAtLogin($0) })
            )
            if model.loginItem == .needsApproval {
                HStack(spacing: 6) {
                    Text("allow tapeq in login items").foregroundStyle(Style.secondary)
                    TextButton("Open settings", action: model.openLoginItemsSettings)
                }
                .font(Style.mono(10))
            }
            if let error = model.loginItemError {
                Text(error)
                    .font(Style.mono(10))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                outputMenu
                Spacer()
                TextButton("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(.top, 2)
    }

    private var outputMenu: some View {
        Menu {
            ForEach(model.outputDevices) { device in
                Button {
                    model.selectOutputDevice(device.id)
                } label: {
                    if device.id == model.defaultOutputID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("OUTPUT").tracking(1).foregroundStyle(Style.secondary)
                Text(currentOutputName.lowercased()).lineLimit(1)
                Text("▾").foregroundStyle(Style.secondary)
            }
            .font(Style.mono(11))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Output device")
        .accessibilityValue(currentOutputName)
    }

    private var currentOutputName: String {
        model.outputDevices.first { $0.id == model.defaultOutputID }?.name ?? "none"
    }
}

// MARK: - Components

/// A 1px-bordered section with an uppercase title bar.
private struct Box<Content: View>: View {
    let title: String
    let detail: String?
    let trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title.uppercased()).tracking(1)
                if let detail {
                    Text(detail).foregroundStyle(Style.secondary)
                }
                Spacer()
                trailing
            }
            .font(Style.mono(11))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Rectangle().fill(Style.border).frame(height: 1)
            content.padding(10)
        }
        .overlay(Rectangle().strokeBorder(Style.border, lineWidth: 1))
    }
}

/// Inverted (white on black) when on, like a lit terminal key.
private struct PowerButton: View {
    let status: AppModel.Status
    let action: () -> Void

    var body: some View {
        let isOn = status != .off && !isFailed
        Button(action: action) {
            Text(status == .starting ? " ··· " : isOn ? " ON  " : " OFF ")
                .font(Style.mono(12))
                .tracking(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .foregroundStyle(isOn ? Style.background : Style.secondary)
                .background(isOn ? Style.text : Style.background)
                .overlay(Rectangle().strokeBorder(isOn ? Style.text : Style.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .starting)
        .accessibilityLabel("Sound processing")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

private struct SelectableCell: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .font(Style.mono(10))
                .lineLimit(1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? Style.background : Style.secondary)
                .background(isSelected ? Style.text : Style.background)
                .overlay(Rectangle().strokeBorder(isSelected ? Style.text : Style.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// `CLARITY   ────●┄┄┄┄┄  6`: a hairline track with step ticks and a round knob.
/// Click or drag anywhere on the track; the knob grows while hovered or dragged.
private struct EffectSlider: View {
    let title: String
    @Binding var value: Float
    @State private var isHovering = false
    @State private var isDragging = false

    private let steps = Int(Effect.range.upperBound)
    private let knobRadius: CGFloat = 5

    var body: some View {
        let level = Int(value.rounded())
        HStack(spacing: 10) {
            Text(title.uppercased())
                .tracking(0.5)
                .foregroundStyle(level > 0 ? Style.text : Style.secondary)
                .frame(width: 128, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                Canvas { context, size in
                    draw(in: &context, size: size, level: level)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isDragging = true
                            let usable = width - knobRadius * 2
                            let fraction = min(max((drag.location.x - knobRadius) / usable, 0), 1)
                            value = Float((fraction * CGFloat(steps)).rounded())
                        }
                        .onEnded { _ in isDragging = false }
                )
                .onHover { isHovering = $0 }
            }
            .frame(height: 18)
            Text("\(level)")
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(level > 0 ? Style.text : Style.secondary)
        }
        .font(Style.mono(11))
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(level)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, Effect.range.upperBound)
            case .decrement: value = max(value - 1, Effect.range.lowerBound)
            @unknown default: break
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, level: Int) {
        let midY = size.height / 2
        let usable = size.width - knobRadius * 2
        func x(_ step: Int) -> CGFloat { knobRadius + usable * CGFloat(step) / CGFloat(steps) }
        let knobX = x(level)

        // Step ticks: passed ones lit, the rest faint.
        for step in 0...steps {
            var tick = Path()
            tick.move(to: CGPoint(x: x(step), y: midY - 3))
            tick.addLine(to: CGPoint(x: x(step), y: midY + 3))
            context.stroke(tick, with: .color(step <= level ? Style.secondary : Style.faint), lineWidth: 1)
        }

        var track = Path()
        track.move(to: CGPoint(x: knobRadius, y: midY))
        track.addLine(to: CGPoint(x: size.width - knobRadius, y: midY))
        context.stroke(track, with: .color(Style.border), lineWidth: 1)

        var fill = Path()
        fill.move(to: CGPoint(x: knobRadius, y: midY))
        fill.addLine(to: CGPoint(x: knobX, y: midY))
        context.stroke(fill, with: .color(Style.text), lineWidth: 2)

        let radius = isDragging || isHovering ? knobRadius + 1.5 : knobRadius
        let knob = Path(ellipseIn: CGRect(x: knobX - radius, y: midY - radius, width: radius * 2, height: radius * 2))
        context.fill(knob, with: .color(level > 0 ? Style.text : Style.secondary))
    }
}

private struct AsciiCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Text(isOn ? "[■]" : "[ ]")
                Text(title.uppercased()).tracking(1)
                    .foregroundStyle(isOn ? Style.text : Style.secondary)
            }
            .font(Style.mono(11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Style.mono(10))
                .tracking(1)
                .foregroundStyle(Style.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
