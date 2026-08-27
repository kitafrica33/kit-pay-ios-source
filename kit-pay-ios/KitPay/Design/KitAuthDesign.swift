import SwiftUI
import UIKit

// The unauthenticated design language: light, open, full-screen layouts in Kit's existing
// palette — a circular brand badge, generous type, PIN dots instead of secure-field boxes, and
// a large glass number pad. No half-screen input cards.

/// Soft, airy canvas shared by every unauthenticated screen.
struct KitAuthBackground: View {
    var body: some View {
        ZStack {
            KitColor.canvas
            Circle()
                .fill(KitColor.paleGreen.opacity(0.55))
                .frame(width: 320, height: 320)
                .blur(radius: 58)
                .offset(x: 160, y: -300)
            Circle()
                .fill(KitColor.navy.opacity(0.07))
                .frame(width: 300, height: 300)
                .blur(radius: 66)
                .offset(x: -170, y: 330)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The circular Kit badge that anchors lock and PIN screens.
struct KitAuthLogoBadge: View {
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            Circle()
                .stroke(.white.opacity(0.8), lineWidth: 0.8)
            KitLogoMarkView(tint: KitColor.navy)
                .frame(width: size * 0.54)
        }
        .frame(width: size, height: size)
        .shadow(color: KitColor.navy.opacity(0.12), radius: 18, y: 8)
    }
}

/// Horizontal shake for a rejected PIN.
struct KitShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 3), y: 0)
        )
    }
}

/// Entry-progress dots: outlined while empty, filled as digits arrive.
struct KitPinDotsView: View {
    let capacity: Int
    let filledCount: Int
    var isError = false
    var isBusy = false

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<capacity, id: \.self) { index in
                Circle()
                    .fill(index < filledCount ? fillColor : Color.clear)
                    .overlay {
                        Circle()
                            .stroke(
                                index < filledCount
                                    ? fillColor
                                    : KitColor.secondaryText.opacity(0.35),
                                lineWidth: 1.8
                            )
                    }
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(filledCount) of \(capacity) digits entered")
    }

    private var fillColor: Color {
        if isError { return .red }
        if isBusy { return KitColor.green }
        return KitColor.primaryText
    }
}

/// The full-screen number pad: big soft circular keys, delete on the right, and an optional
/// helper (forgot / biometric) on the left of the zero row.
struct KitNumberPad: View {
    enum Accessory {
        case none
        case action(title: String, action: () -> Void)
        case biometric(symbolName: String, label: String, action: () -> Void)
    }

    var isEnabled = true
    var accessory: Accessory = .none
    let onDigit: (Int) -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let keyDiameter: CGFloat = 76
    private static let rowSpacing: CGFloat = 14
    private static let columnSpacing: CGFloat = 24

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: Self.columnSpacing) {
                    ForEach(row, id: \.self) { digit in
                        digitKey(digit)
                    }
                }
            }
            HStack(spacing: Self.columnSpacing) {
                accessoryKey
                digitKey(0)
                deleteKey
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
        .disabled(!isEnabled)
    }

    private func digitKey(_ digit: Int) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDigit(digit)
        } label: {
            Text("\(digit)")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(KitColor.primaryText)
                .frame(width: Self.keyDiameter, height: Self.keyDiameter)
                .background {
                    if reduceTransparency {
                        Circle().fill(Color(UIColor.secondarySystemBackground))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(.white.opacity(0.42))
                    }
                }
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.72), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
        }
        .buttonStyle(KitNumberPadKeyStyle())
        .accessibilityLabel("\(digit)")
    }

    private var deleteKey: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDelete()
        } label: {
            Image(systemName: "delete.left.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(KitColor.secondaryText)
                .frame(width: Self.keyDiameter, height: Self.keyDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(KitNumberPadKeyStyle())
        .accessibilityLabel("Delete")
    }

    @ViewBuilder
    private var accessoryKey: some View {
        switch accessory {
        case .none:
            Color.clear
                .frame(width: Self.keyDiameter, height: Self.keyDiameter)
                .accessibilityHidden(true)
        case let .action(title, action):
            Button(action: action) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .minimumScaleFactor(0.7)
                    .frame(width: Self.keyDiameter, height: Self.keyDiameter)
                    .contentShape(Circle())
            }
            .buttonStyle(KitNumberPadKeyStyle())
        case let .biometric(symbolName, label, action):
            Button(action: action) {
                Image(systemName: symbolName)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(KitColor.green)
                    .frame(width: Self.keyDiameter, height: Self.keyDiameter)
                    .contentShape(Circle())
            }
            .buttonStyle(KitNumberPadKeyStyle())
            .accessibilityLabel(label)
        }
    }
}

private struct KitNumberPadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One full-screen PIN page in the reference layout: badge, title, dots, pad. The caller owns
/// the digits and submission; the page owns layout, haptics, shake, and auto-fill callbacks.
struct KitPinEntryPage<Footer: View>: View {
    let title: String
    let subtitle: String
    var capacity = 4
    @Binding var pin: String
    var errorMessage: String?
    var isBusy = false
    var accessory: KitNumberPad.Accessory = .none
    var onFilled: (String) -> Void
    @ViewBuilder var footer: Footer

    @State private var shakes: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                KitAuthBackground()
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 20)
                        KitAuthLogoBadge()
                        Spacer(minLength: 12)
                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(KitColor.primaryText)
                            .multilineTextAlignment(.center)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(KitColor.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .padding(.top, 6)
                        Spacer(minLength: 14)
                        ZStack {
                            KitPinDotsView(
                                capacity: capacity,
                                filledCount: pin.count,
                                isError: errorMessage != nil,
                                isBusy: isBusy
                            )
                            .modifier(KitShakeEffect(animatableData: shakes))
                            .opacity(isBusy ? 0.35 : 1)
                            if isBusy {
                                ProgressView()
                                    .tint(KitColor.green)
                            }
                        }
                        .frame(height: 30)
                        Group {
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            } else {
                                Text(" ")
                                    .font(.footnote)
                            }
                        }
                        .padding(.top, 10)
                        Spacer(minLength: 16)
                        KitNumberPad(
                            isEnabled: !isBusy,
                            accessory: accessory,
                            onDigit: appendDigit,
                            onDelete: deleteDigit
                        )
                        footer
                            .padding(.top, 14)
                        Spacer(minLength: max(10, geometry.safeAreaInsets.bottom > 0 ? 10 : 18))
                    }
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onChange(of: errorMessage) { previous, current in
            guard current != nil, current != previous else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if reduceMotion {
                return
            }
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
    }

    private func appendDigit(_ digit: Int) {
        guard pin.count < capacity else { return }
        pin.append("\(digit)")
        if pin.count == capacity {
            // Let the final dot render before the caller submits or transitions.
            let submitted = pin
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard pin == submitted else { return }
                onFilled(submitted)
            }
        }
    }

    private func deleteDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }
}
