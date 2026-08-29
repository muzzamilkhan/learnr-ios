import SwiftUI
import LearnrEngine

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        switch session.state {
        case .loading:
            ProgressView().controlSize(.large)

        case .signedOut:
            CodeEntryView()

        case .signedIn(let account):
            HomeView(account: account)

        case .demo:
            // The same home screen a signed-in child sees. What differs is what
            // it is handed: no queue, and no reads (ledger `L26`).
            HomeView(account: .unread)
        }
    }
}

/// Where a signed-in child lands.
struct HomeView: View {
    let account: Account
    @Environment(Session.self) private var session
    @State private var playing = false
    @State private var speeding = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("Hello\(account.name.map { ", \($0)" } ?? "")")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)

                // What yesterday came to. Absent entirely until something has
                // been read: a child who has never been fetched sees the screen
                // they saw before this existed, rather than two zeros claiming
                // they have nothing.
                if let player = session.player {
                    StatsRow(player: player)
                }

                Button {
                    playing = true
                } label: {
                    VStack(spacing: 6) {
                        Text("Play")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(session.level.label)
                            .font(.system(size: 17, weight: .medium))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 132)
                    .background(Palette.brand, in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(.horizontal, 40)

                // Second, and smaller. A sitting is the thing a child is here
                // for; a speed run is the thing they choose on purpose.
                Button {
                    speeding = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Speed")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Palette.brand)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Palette.brandSoft, in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(.horizontal, 40)

                if session.pendingAttempts > 0 {
                    Label("\(session.pendingAttempts) answers waiting to sync",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(Palette.inkSoft)
                }

                Spacer()

                Button(session.isDemo ? "Finish looking around" : "Sign out") {
                    if session.isDemo {
                        session.leaveDemo()
                    } else {
                        Task { await session.signOut() }
                    }
                }
                .foregroundStyle(Palette.inkSoft)
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $playing) {
            PlayView(
                level: session.level,
                queue: session.isDemo ? nil : session.queue,
                api: session.isDemo ? nil : session.api)
                .environment(session)
        }
        .fullScreenCover(isPresented: $speeding) {
            SpeedPickerView()
                .environment(session)
        }
        .task {
            // Demo reads nothing and caches nothing: it has no account to read
            // for, and a write here would outlive the session it belongs to.
            guard !session.isDemo else { return }

            // The cache first, and synchronously: it carries the level, and an
            // offline launch would otherwise refresh the fallback level's pack
            // rather than the one this child plays.
            session.restorePlayer()
            await session.refreshPendingCount()
            // Then the server, which brings the level and the figures together
            // and leaves both alone if it cannot be reached.
            await session.refreshPlayer()
            await session.refreshContent()
        }
    }
}

/// Stars and a streak, between the greeting and the Play button.
///
/// Read-only and past tense: this is what a child has already done, not
/// something to act on. The buttons beneath it are the actions, and nothing
/// here competes with them for the tap.
private struct StatsRow: View {
    let player: PlayerSnapshot

    var body: some View {
        HStack(spacing: 14) {
            if player.showsStars {
                Stat(symbol: "star.fill",
                     tint: Palette.brand,
                     value: "\(player.stars)",
                     label: player.stars == 1 ? "star" : "stars")
            }
            if player.showsStreak {
                Stat(symbol: "flame.fill",
                     tint: Palette.wrong,
                     value: "\(player.streakDays)",
                     label: player.streakDays == 1 ? "day" : "days")
            }
        }
        // One label for the pair, so VoiceOver reads "24 stars, 3 days" rather
        // than stopping on each glyph.
        .accessibilityElement(children: .combine)
    }

    private struct Stat: View {
        let symbol: String
        let tint: Color
        let value: String
        let label: String

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                // The number leads and the word follows it, small: a child
                // reading "24" first gets the figure they came for.
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.card, in: Capsule())
            .accessibilityLabel("\(value) \(label)")
        }
    }
}
