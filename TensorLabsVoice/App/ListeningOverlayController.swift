import AppKit
import SwiftUI

@MainActor
final class ListeningOverlayController {
    fileprivate final class OverlayModel: ObservableObject {
        @Published var level: CGFloat = 0.05
        @Published var status: String = "Listening"
        @Published var transcript: String = "Listening..."
    }

    private let model = OverlayModel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            panel = buildPanel()
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        model.level = 0.05
        model.status = "Listening"
        model.transcript = "Listening..."
    }

    func updateLevel(_ level: Float) {
        model.level = min(max(CGFloat(level), 0.02), 1.0)
    }

    func updateTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        model.transcript = trimmed.isEmpty ? "Listening..." : trimmed
    }

    func updateStatus(_ status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        model.status = trimmed.isEmpty ? "Listening" : trimmed
    }

    private func buildPanel() -> NSPanel {
        let view = ListeningOverlayView(model: model)
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 108),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        return panel
    }

    private func positionPanel() {
        guard let panel else { return }
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.maxY - panel.frame.height - 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct ListeningOverlayView: View {
    @ObservedObject var model: ListeningOverlayController.OverlayModel

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let accent = 0.2 + (0.8 * model.level)

            VStack(spacing: 10) {
                Text(model.status.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                HStack(spacing: 7) {
                    ForEach(0..<20, id: \.self) { idx in
                        let phase = t * 9 + Double(idx) * 0.38
                        let wave = 0.35 + 0.65 * sin(phase)
                        let normalized = max(0.1, CGFloat(wave))
                        let height = 8 + (44 * accent * normalized)
                        let hue = (Double(idx) / 20.0) + (sin(t * 0.6) * 0.04)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hue: hue, saturation: 0.75, brightness: 1.0),
                                        Color(hue: hue + 0.08, saturation: 0.9, brightness: 0.85),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 9, height: height)
                            .shadow(
                                color: Color(hue: hue, saturation: 0.8, brightness: 1.0).opacity(0.5),
                                radius: 5,
                                x: 0,
                                y: 0
                            )
                    }
                }

                Text(model.transcript)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .animation(.easeOut(duration: 0.12), value: model.transcript)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .overlay(alignment: .top) {
                HStack(spacing: 7) {
                    ForEach(0..<20, id: \.self) { _ in
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 9, height: 2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}
