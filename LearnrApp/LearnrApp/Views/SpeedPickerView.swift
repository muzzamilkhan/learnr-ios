import SwiftUI
import LearnrEngine

/// Choosing what to speed-run: the operation, then the mode within it.
///
/// Two steps rather than one list of twenty-six. The multiply block is fourteen
/// of them, so a single list is mostly times tables however it is grouped — and
/// a child who came to practise their sevens should not scroll past addition to
/// find them.
///
/// Both screens read their contents from `Modes`, which declares the order. The
/// picker never builds a mode from parts; it only ever shows ones the engine
/// enumerated.
struct SpeedPickerView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    // Qualified: `Operation` alone is ambiguous against Foundation's.
    @State private var operation: LearnrEngine.Operation?
    @State private var running: Mode?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                operations
            }
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .navigationDestination(item: $operation) { op in
                modes(for: op)
            }
        }
        .fullScreenCover(item: $running) { mode in
            SpeedRunView(mode: mode)
                .environment(session)
        }
    }

    // MARK: Step one — the operation

    private var operations: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Ninety seconds. How many can you get?")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                ForEach(LearnrEngine.Operation.allCases, id: \.self) { op in
                    Button {
                        operation = op
                    } label: {
                        HStack(spacing: 18) {
                            Text(Modes.operationGlyph(op))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.brand)
                                .frame(width: 64, height: 64)
                                .background(Palette.brandSoft, in: RoundedRectangle(cornerRadius: 18))

                            Text(Modes.operationLabel(op))
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.ink)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Palette.inkSoft)
                        }
                        .padding(16)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: Step two — the mode

    private func modes(for op: LearnrEngine.Operation) -> some View {
        let modes = Modes.modesFor(op)

        return ScrollView {
            // Two columns. The graded operations have three modes and the
            // multiply block fourteen, and a grid of chips suits both — where a
            // list would leave the three-mode screens mostly empty.
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                ForEach(modes, id: \.key) { mode in
                    Button {
                        running = mode
                    } label: {
                        Text(Modes.modeLabel(mode))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 92)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                // The one difficulty ramp, as a stripe down the
                                // leading edge: green at the easy end, purple at
                                // the hard one. `modeHardness` is what puts a
                                // bundle between its tables and `all` in the
                                // middle, so the chips read in the order they
                                // are actually ordered.
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Self.rampColour(Modes.modeHardness(mode)), lineWidth: 3)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Palette.paper)
        .navigationTitle(Modes.operationLabel(op))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Green through amber to purple, across the hardness ramp.
    ///
    /// Two segments rather than one sweep: interpolating straight from green to
    /// purple passes through the blues, which puts the *middle* of the ramp
    /// further from both ends than either end is from the other. Amber at the
    /// halfway point is what makes it read as a ramp at all.
    static func rampColour(_ hardness: Double) -> Color {
        let clamped = min(max(hardness, 0), 1)
        // Hue runs green (0.33) → amber (0.10) → purple (0.78, i.e. going down
        // through red and wrapping).
        let hue: Double = clamped <= 0.5
            ? 0.33 - 0.23 * (clamped / 0.5)
            : (0.10 - 0.32 * ((clamped - 0.5) / 0.5)).truncatingRemainder(dividingBy: 1) + 1
        return Color(hue: hue.truncatingRemainder(dividingBy: 1),
                     saturation: 0.62, brightness: 0.78)
    }
}

/// So a `Mode` can drive `fullScreenCover(item:)`. The key is already the
/// canonical identity — it is what the server stores and what `parseMode` reads
/// back — so there is nothing else it could sensibly be.
extension Mode: @retroactive Identifiable {
    public var id: String { key }
}

extension LearnrEngine.Operation: @retroactive Identifiable {
    public var id: String { rawValue }
}
