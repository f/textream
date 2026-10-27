import SwiftUI

struct PrompterNavigationControls: View {
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            navigationButton(.beginning, symbol: "backward.end.fill",
                             label: "Go to Beginning (⌘↑)")
            navigationButton(.backSentence, symbol: "backward.fill",
                             label: "Previous Sentence (←)")
            navigationButton(.backOneScreen, symbol: "gobackward",
                             label: "Previous Screen (↑)")
        }
    }

    private func navigationButton(_ command: PromptNavigationCommand,
                                  symbol: String, label: String) -> some View {
        Button {
            TextreamService.shared.navigatePrompter(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: size, height: size)
                .background(.white.opacity(0.15))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
