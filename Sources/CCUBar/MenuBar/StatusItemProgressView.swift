import AppKit

/// A compact bar + percentage label shown inside the menu bar.
/// Supports three display styles chosen in Settings.
final class StatusItemProgressView: NSView {
    enum Mode {
        case progress(percent: Double, tier: GaugeTier)
        case loading
        case error(short: String)
    }

    var displayMode: MenuBarDisplayMode = .both {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    var showIcon: Bool = true {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private var mode: Mode = .loading
    private let trackWidth: CGFloat = 42
    private let trackHeight: CGFloat = 8
    private let horizontalPadding: CGFloat = 4
    private let textLeading: CGFloat = 6
    private let iconTrailing: CGFloat = 4
    private let iconCharacter = "🤖"
    private let iconFont = NSFont.systemFont(ofSize: 13)

    override var intrinsicContentSize: NSSize {
        let labelWidth = labelMaxWidth()
        let contentWidth: CGFloat
        switch displayMode {
        case .numeric:
            contentWidth = labelWidth
        case .bar:
            contentWidth = trackWidth
        case .both:
            contentWidth = trackWidth + textLeading + labelWidth
        }
        let iconWidth = showIcon ? (iconSize().width + iconTrailing) : 0
        let total = horizontalPadding * 2 + iconWidth + contentWidth
        return NSSize(width: total, height: NSStatusBar.system.thickness)
    }

    private func iconSize() -> NSSize {
        let attributed = NSAttributedString(
            string: iconCharacter,
            attributes: [.font: iconFont]
        )
        return attributed.size()
    }

    override var isFlipped: Bool { false }

    func update(mode: Mode) {
        self.mode = mode
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let midY = bounds.midY
        var contentOriginX = horizontalPadding

        if showIcon {
            let iconAttributed = NSAttributedString(
                string: iconCharacter,
                attributes: [.font: iconFont]
            )
            let size = iconAttributed.size()
            iconAttributed.draw(at: NSPoint(
                x: contentOriginX,
                y: midY - size.height / 2
            ))
            contentOriginX += size.width + iconTrailing
        }

        let trackRect = NSRect(
            x: contentOriginX,
            y: midY - trackHeight / 2,
            width: trackWidth,
            height: trackHeight
        )

        switch mode {
        case .progress(let percent, let tier):
            if displayMode != .numeric {
                drawTrack(in: trackRect)
                let clamped = max(0, min(100, percent)) / 100.0
                let fillWidth = max(2, trackRect.width * CGFloat(clamped))
                let fillRect = NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: fillWidth,
                    height: trackRect.height
                )
                fillColor(for: tier).setFill()
                NSBezierPath(roundedRect: fillRect,
                             xRadius: trackHeight / 2,
                             yRadius: trackHeight / 2).fill()
            }
            if displayMode != .bar {
                drawLabel(String(format: "%.0f%%", percent), color: textColor(for: tier), trackRect: trackRect)
            }

        case .loading:
            if displayMode != .numeric {
                drawTrack(in: trackRect)
            }
            if displayMode != .bar {
                drawLabel("…", color: .secondaryLabelColor, trackRect: trackRect)
            }

        case .error(let short):
            if displayMode != .numeric {
                drawTrack(in: trackRect, dimmed: true)
            }
            // Error label always shown (even in bar-only mode, to signal the issue).
            drawLabel(short, color: .systemOrange, trackRect: trackRect)
        }
    }

    private func drawTrack(in rect: NSRect, dimmed: Bool = false) {
        let trackColor = NSColor.secondaryLabelColor.withAlphaComponent(dimmed ? 0.12 : 0.2)
        trackColor.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        ).fill()
    }

    private func drawLabel(_ text: String, color: NSColor, trackRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let originX: CGFloat
        switch displayMode {
        case .numeric:
            originX = trackRect.minX
        case .bar:
            // Used only for error fallback — draw at the track origin.
            originX = trackRect.minX
        case .both:
            originX = trackRect.maxX + textLeading
        }
        let point = NSPoint(
            x: originX,
            y: bounds.midY - textSize.height / 2
        )
        attributed.draw(at: point)
    }

    private func labelMaxWidth() -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let sample: NSString
        switch mode {
        case .progress: sample = "100%"
        case .loading: sample = "…"
        case .error(let s): sample = s as NSString
        }
        return sample.size(withAttributes: [.font: font]).width
    }

    private func fillColor(for tier: GaugeTier) -> NSColor {
        switch tier {
        case .normal: return NSColor(red: 0.22, green: 0.82, blue: 0.40, alpha: 1.0)
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    private func textColor(for tier: GaugeTier) -> NSColor {
        switch tier {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
