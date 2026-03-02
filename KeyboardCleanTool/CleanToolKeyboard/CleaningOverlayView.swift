import SwiftUI

struct CleaningOverlayView: View {
    @ObservedObject var manager: CleaningManager

    var body: some View {
        ZStack {
            Color.black

            VStack {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.6))

                    Text("Cleaning Screen & Keyboard")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.white.opacity(0.8))

                    Text("Keyboard and trackpad are disabled")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                // Exit progress area
                VStack(spacing: 12) {
                    if manager.isExiting {
                        Text("Exiting cleaning mode...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .transition(.opacity)
                    }

                    // Progress bar — fills from center to edges
                    GeometryReader { geometry in
                        ZStack {
                            // Background track
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(manager.isExiting ? 0.15 : 0))
                                .frame(height: 6)

                            // Fill bar (centered, expands outward)
                            if manager.isExiting {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.9))
                                    .frame(
                                        width: geometry.size.width * manager.exitProgress,
                                        height: 6
                                    )
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    .padding(.horizontal, 100)

                    if !manager.isExiting {
                        Text("Hold ⌘L + ⌘R to exit")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .padding(.bottom, 50)
                .animation(.easeInOut(duration: 0.3), value: manager.isExiting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
