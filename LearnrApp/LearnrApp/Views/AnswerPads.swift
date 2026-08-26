import SwiftUI
import LearnrEngine

/// The three ways a question can be answered, as three pads.
///
/// Which one renders is `Answers.answerMode`'s call, decided from the question
/// itself — the screen only has to draw what it is told. Ported from
/// `number-pad.tsx`, `letter-pad.tsx` and `choice-pad.tsx`.

/// An on-screen pad rather than the system keyboard: it keeps the question
/// visible, gives large fixed targets, and stops a child wandering into other
/// keys.
///
/// Laid out like a calculator, with the tick down the right-hand side. The
/// decimal point is always offered rather than shown only for questions that
/// need one — a key that appeared exactly when the answer was fractional would
/// give the answer away.
struct NumberPad: View {
    var disabled = false
    var canCheck = false
    let onDigit: (String) -> Void
    let onBackspace: () -> Void
    let onCheck: () -> Void

    private static let rows: [[String]] = [
        ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"],
    ]

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { digit in
                            PadKey(digit, disabled: disabled) { onDigit(digit) }
                        }
                    }
                }
                HStack(spacing: 10) {
                    PadKey(".", label: "Decimal point", disabled: disabled) { onDigit(".") }
                    PadKey("0", disabled: disabled) { onDigit("0") }
                    PadKey(
                        systemImage: "delete.left", label: "Delete", disabled: disabled,
                        action: onBackspace)
                }
            }

            // The tick, full height down the fourth column. Brand-filled
            // because it is the key that ends something, which is the one thing
            // a digit never does.
            Button(action: onCheck) {
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.brand, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PadButtonStyle())
            .disabled(disabled || !canCheck)
            .opacity(disabled || !canCheck ? 0.3 : 1)
            .frame(width: 96)
            .accessibilityLabel("Check")
        }
    }
}

/// Letters, for the handful of questions answered with a word.
///
/// A-Z and a space, laid out as a keyboard rather than a calculator, with the
/// same tick and delete the number pad has.
struct LetterPad: View {
    var disabled = false
    var canCheck = false
    let onLetter: (String) -> Void
    let onBackspace: () -> Void
    let onCheck: () -> Void

    // Written out rather than built with `Array("QWERTY").map(String.init)`,
    // which the type checker cannot resolve inside a view body in reasonable
    // time.
    private static let rows: [[String]] = [
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
        ["Z", "X", "C", "V", "B", "N", "M"],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { letter in
                        PadKey(letter, disabled: disabled, fontSize: 22) { onLetter(letter) }
                    }
                }
            }
            HStack(spacing: 6) {
                PadKey(
                    systemImage: "delete.left", label: "Delete", disabled: disabled,
                    action: onBackspace)
                PadKey("space", label: "Space", disabled: disabled, fontSize: 17) {
                    onLetter(" ")
                }
                Button(action: onCheck) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.brand, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(PadButtonStyle())
                .disabled(disabled || !canCheck)
                .opacity(disabled || !canCheck ? 0.3 : 1)
                .accessibilityLabel("Check")
            }
            .frame(height: 56)
        }
    }
}

/// The options for a tapped question — true/false, or a template's own choices.
///
/// A tap commits on the first touch: there is nothing to review, so no Check
/// key. That is `answerMode`'s distinction, not this view's.
struct ChoicePad: View {
    let options: [AnswerOption]
    var disabled = false
    let onChoose: (String) -> Void

    var body: some View {
        // Two columns for four options, one row for two — a row of four narrow
        // buttons is harder to hit than a grid of two wide ones.
        let columns = options.count > 2 ? 2 : options.count

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: max(columns, 1)),
            spacing: 12
        ) {
            ForEach(options, id: \.value) { option in
                Button {
                    onChoose(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Palette.line, lineWidth: 2))
                }
                .buttonStyle(PadButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
        }
    }
}

// MARK: - Shared

/// One key. Flat, bordered and large, like every control in this app.
private struct PadKey: View {
    let title: String?
    let systemImage: String?
    let label: String?
    let disabled: Bool
    let fontSize: CGFloat
    let action: () -> Void

    init(
        _ title: String, label: String? = nil, disabled: Bool,
        fontSize: CGFloat = 30, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = nil
        self.label = label
        self.disabled = disabled
        self.fontSize = fontSize
        self.action = action
    }

    init(
        systemImage: String, label: String, disabled: Bool,
        fontSize: CGFloat = 24, action: @escaping () -> Void
    ) {
        self.title = nil
        self.systemImage = systemImage
        self.label = label
        self.disabled = disabled
        self.fontSize = fontSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(.system(size: fontSize, weight: .semibold, design: .rounded))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: fontSize, weight: .medium))
                }
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Palette.line, lineWidth: 2))
        }
        .buttonStyle(PadButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label ?? title ?? "")
    }
}

/// `active:scale-95` — the press feedback every control in the web app has.
private struct PadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
