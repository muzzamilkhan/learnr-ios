import SwiftUI
import LearnrEngine

/// Signing in: a child types the four characters their parent gave them.
///
/// **The one screen that uses the system keyboard.** Everywhere else the app
/// draws its own pad, because a question is answered over and over and the
/// targets must not move. This is typed once, by a child sitting next to the
/// grown-up reading the code out, and a keyboard they already know beats one
/// they have to learn — autocorrect and prediction are off, so nothing rewrites
/// what they typed.
///
/// The charset is not typeable as-is, so the field is a filter rather than a
/// free text box: input is uppercased, and anything outside the charset is
/// dropped as it lands. `.asciiCapable` rather than `.numberPad` because a code
/// is letters *and* digits — a number pad could not enter most codes at all.
struct CodeEntryView: View {
    @Environment(Session.self) private var session

    @State private var entry = ""
    @State private var error: String?
    @State private var busy = false
    @State private var showingGate = false
    @FocusState private var typing: Bool

    /// The server's charset, minus the characters a child would misread:
    /// no O or 0, no I, L or 1.
    private static let charset = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let length = 4

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text("Type your code")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text("Your grown-up will give it to you.")
                .font(.title3)
                .foregroundStyle(.secondary)

            boxes

            if let error {
                Text(error)
                    .font(.headline)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            // Reachable in the shipped build, because a reviewer uses the same
            // binary as every child (ledger `L26`). Worded for both: a child
            // who taps it gets maths that does not count, which is a fair thing
            // for it to be.
            Button {
                session.enterDemo()
            } label: {
                HStack(spacing: 6) {
                    Text("Have a look around")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.brand)
            }
            .padding(.top, 4)

            // One external link, gated. Account-only wording: no prices and
            // nothing that reads as a purchase route (Guideline 3.1.1).
            Button {
                showingGate = true
            } label: {
                Text("New here? Grown-ups can set up an account")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .underline()
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: 560)
        .animation(.snappy, value: entry)
        .animation(.snappy, value: error)
        // The keyboard is the whole point of this screen, so it opens on
        // arrival rather than waiting for a tap on something that does not look
        // like a text field.
        .onAppear { typing = true }
        .sheet(isPresented: $showingGate) { GrownUpGateSheet() }
    }

    /// Four boxes, with the real field behind them taking the keystrokes.
    ///
    /// The boxes are what a child sees; the `TextField` owns the keyboard and
    /// the caret. It is given the boxes' own footprint rather than sized to
    /// nothing — a zero-sized field is a thing iOS is entitled to treat as not
    /// really on screen — and drawn in a colour nothing shows through, so the
    /// caret and selection stay invisible behind the boxes.
    private var boxes: some View {
        ZStack {
            // The boxes are drawn first so the field lands on top of them: the
            // field must be the thing a tap reaches, or tapping a box that
            // *looks* like the input does nothing. An earlier version put a
            // screen-wide `onTapGesture` above the field instead, which
            // swallowed every tap meant for it — so once the keyboard was
            // dismissed there was no way back to it.
            characterBoxes

            TextField("", text: $entry)
                .focused($typing)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .submitLabel(.go)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .tint(.clear)
                .foregroundStyle(.clear)
                .frame(width: 68 * 4 + 14 * 3, height: 84)
                .accessibilityLabel("Your code")
                .onChange(of: entry) { _, typed in
                    let cleaned = Self.clean(typed)
                    if cleaned != typed { entry = cleaned }
                    error = nil

                    // Four characters is the whole code, so submit rather than
                    // asking a child to find a button that is only ever
                    // pressed once.
                    if cleaned.count == Self.length {
                        Task { await submit() }
                    }
                }

        }
    }

    /// What a child actually sees. Purely decorative — every tap goes to the
    /// field above it, and VoiceOver reads the field rather than four boxes.
    private var characterBoxes: some View {
        HStack(spacing: 14) {
            ForEach(0..<Self.length, id: \.self) { index in
                let characters = Array(entry)
                let character = index < characters.count ? String(characters[index]) : ""

                Text(character)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .frame(width: 68, height: 84)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                index == entry.count && typing
                                    ? Color.accentColor : .clear,
                                lineWidth: 3)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    /// Uppercased, filtered to the charset, and cut to length.
    ///
    /// Done on every change rather than on submit: a character the code cannot
    /// contain never appears in a box, so a child is never left deleting
    /// something they were allowed to type. Paste goes through the same filter,
    /// which is what makes a pasted code with spaces or dashes work.
    static func clean(_ typed: String) -> String {
        String(typed.uppercased().filter(charset.contains).prefix(length))
    }

    private func submit() async {
        busy = true
        defer { busy = false }

        // Closed while the code is checked, so a child is not typing into a
        // field that is about to be cleared under them.
        typing = false

        do {
            try await session.signIn(code: entry)
        } catch ApiError.unauthorised {
            error = "That code did not work. Ask for a new one."
            entry = ""
            typing = true
        } catch {
            // A code is redeemed against the server, so there is no offline
            // path in - say so plainly rather than blaming the child's typing.
            self.error = "Could not reach LearnR. Check the wifi and try again."
            entry = ""
            typing = true
        }
    }
}
