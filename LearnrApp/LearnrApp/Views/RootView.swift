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
        }
    }
}

/// Where a signed-in child lands.
struct HomeView: View {
    let account: Account
    @Environment(Session.self) private var session
    @State private var playing = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("Hello\(account.name.map { ", \($0)" } ?? "")")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)

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

                if session.pendingAttempts > 0 {
                    Label("\(session.pendingAttempts) answers waiting to sync",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(Palette.inkSoft)
                }

                Spacer()

                Button("Sign out") {
                    Task { await session.signOut() }
                }
                .foregroundStyle(Palette.inkSoft)
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $playing) {
            PlayView(level: session.level)
                .environment(session)
        }
        .task {
            await session.refreshPendingCount()
            await session.refreshLevel()
        }
    }
}
