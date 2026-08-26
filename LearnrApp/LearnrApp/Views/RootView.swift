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
///
/// A placeholder: it can say who is signed in and what is waiting to sync, but
/// it cannot offer a question yet. Generating one needs the content pack and
/// the template engine, which are build-order steps 2 to 4 and are not written.
/// Saying so on screen is better than a button that cannot work.
struct HomeView: View {
    let account: Account
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Hello\(account.name.map { ", \($0)" } ?? "")")
                .font(.system(size: 40, weight: .bold, design: .rounded))

            VStack(spacing: 8) {
                Text("The question engine is not finished yet.")
                    .font(.title3)
                Text("The RNG and the expression language are ported and verified. "
                     + "Templates, figures and the session engine are still to come.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)

            if session.pendingAttempts > 0 {
                Label("\(session.pendingAttempts) answers waiting to sync",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Sign out") {
                Task { await session.signOut() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .task { await session.refreshPendingCount() }
    }
}
