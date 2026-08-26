import SwiftUI
import LearnrEngine

/// Signing in: a child types the four characters their parent gave them.
///
/// The keyboard never opens. The web app made that choice for the iPad and it
/// holds here for the same reasons - the targets stay large and fixed, nothing
/// reflows under the child's hands, and the only keys on screen are keys that
/// can produce a valid code.
struct CodeEntryView: View {
    @Environment(Session.self) private var session

    @State private var entry = ""
    @State private var error: String?
    @State private var busy = false

    /// The server's charset, minus the characters a child would misread:
    /// no O or 0, no I, L or 1.
    private static let charset = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let length = 4

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
    }

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

            pad

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: 560)
        .animation(.snappy, value: entry)
        .animation(.snappy, value: error)
    }

    private var boxes: some View {
        HStack(spacing: 14) {
            ForEach(0..<Self.length, id: \.self) { index in
                let character = index < entry.count
                    ? String(Array(entry)[index])
                    : ""

                Text(character)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .frame(width: 68, height: 84)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(index == entry.count ? Color.accentColor : .clear,
                                    lineWidth: 3)
                    )
            }
        }
    }

    private var pad: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.charset, id: \.self) { character in
                    Button {
                        append(character)
                    } label: {
                        Text(String(character))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || entry.count >= Self.length)
                }
            }

            Button(role: .destructive) {
                entry = ""
                error = nil
            } label: {
                Label("Clear", systemImage: "delete.left")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .disabled(busy || entry.isEmpty)
        }
    }

    private func append(_ character: Character) {
        guard entry.count < Self.length else { return }
        error = nil
        entry.append(character)

        // Four characters is the whole code, so submit rather than asking a
        // child to find a button that is only ever pressed once.
        if entry.count == Self.length {
            Task { await submit() }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }

        do {
            try await session.signIn(code: entry)
        } catch ApiError.unauthorised {
            error = "That code did not work. Ask for a new one."
            entry = ""
        } catch {
            // A code is redeemed against the server, so there is no offline
            // path in - say so plainly rather than blaming the child's typing.
            self.error = "Could not reach LearnR. Check the wifi and try again."
            entry = ""
        }
    }
}
