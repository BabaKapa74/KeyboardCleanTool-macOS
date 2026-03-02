import SwiftUI

struct ContentView: View {
    @EnvironmentObject var cleaningManager: CleaningManager

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "keyboard")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Clean Tool")
                .font(.system(size: 32, weight: .bold))

            Text("Disables keyboard and trackpad\nfor safe cleaning")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: {
                cleaningManager.startCleaning()
            }) {
                Label("Start Cleaning", systemImage: "sparkles")
                    .font(.title3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("To exit: hold ⌘L + ⌘R for 3 seconds")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(50)
        .frame(width: 400, height: 350)
    }
}
