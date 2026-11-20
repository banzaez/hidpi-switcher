import AppKit

/// Состояние иконки приложения в строке меню macOS.
enum MenuBarIconState: Hashable {
    case hidpi
    case virtualHiDPI
    case standard
    case pendingRevert
}

/// Генератор нативных векторных template-иконок для строки меню macOS.
/// Автоматически адаптируется под светлую/тёмную тему, прозрачность обоев и Retina-масштабирование.
@MainActor
enum MenuBarIcon {
    private static let iconSize = NSSize(width: 21, height: 18)

    private static let cachedImages: [MenuBarIconState: NSImage] = [
        .hidpi: renderIcon(for: .hidpi),
        .virtualHiDPI: renderIcon(for: .virtualHiDPI),
        .standard: renderIcon(for: .standard),
        .pendingRevert: renderIcon(for: .pendingRevert)
    ]

    static func image(for state: MenuBarIconState) -> NSImage {
        cachedImages[state] ?? renderIcon(for: state)
    }

    private static func renderIcon(for state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            switch state {
            case .hidpi:
                drawMonitor(in: rect, filled: true, badge: "2×", isVirtual: false)
            case .virtualHiDPI:
                drawMonitor(in: rect, filled: true, badge: "2×", isVirtual: true)
            case .standard:
                drawMonitor(in: rect, filled: false, badge: "1×", isVirtual: false)
            case .pendingRevert:
                drawMonitor(in: rect, filled: false, badge: nil, isVirtual: false)
                drawRevertGlyph(in: NSRect(x: 2.0, y: 4.5, width: 17.0, height: 11.5))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawMonitor(
        in rect: NSRect,
        filled: Bool,
        badge: String?,
        isVirtual: Bool
    ) {
        let ink = NSColor.black
        let screenRect = isVirtual
            ? NSRect(x: 1.5, y: 4.2, width: 15.8, height: 10.8)
            : NSRect(x: 2.0, y: 4.5, width: 17.0, height: 11.5)

        // Вторая «теневая» рамка сверху-справа для режима виртуального HiDPI-буфера
        if isVirtual {
            let backPath = NSBezierPath()
            let backRect = NSRect(
                x: screenRect.minX + 2.2,
                y: screenRect.minY + 2.0,
                width: screenRect.width,
                height: screenRect.height
            )
            let r: CGFloat = 2.2
            backPath.move(to: NSPoint(x: backRect.minX + 1.5, y: backRect.maxY))
            backPath.line(to: NSPoint(x: backRect.maxX - r, y: backRect.maxY))
            backPath.appendArc(
                withCenter: NSPoint(x: backRect.maxX - r, y: backRect.maxY - r),
                radius: r,
                startAngle: 90,
                endAngle: 0,
                clockwise: true
            )
            backPath.line(to: NSPoint(x: backRect.maxX, y: backRect.minY + 1.5))
            backPath.lineWidth = 1.25
            backPath.lineCapStyle = .round
            ink.setStroke()
            backPath.stroke()
        }

        // Ножка и подставка монитора (выровнены по центру основного экрана)
        let centerX = screenRect.midX
        let neckRect = NSRect(x: centerX - 1.15, y: 2.2, width: 2.3, height: 2.3)
        let baseRect = NSRect(x: centerX - 4.0, y: 1.5, width: 8.0, height: 1.35)

        ink.setFill()
        NSBezierPath(rect: neckRect).fill()
        NSBezierPath(roundedRect: baseRect, xRadius: 0.675, yRadius: 0.675).fill()

        // Корпус экрана
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2.3, yRadius: 2.3)
        if filled {
            ink.setFill()
            screenPath.fill()
        } else {
            screenPath.lineWidth = 1.35
            ink.setStroke()
            screenPath.stroke()
        }

        // Бейдж разрешения ("2×" или "1×")
        if let badge {
            drawBadge(badge, centeredIn: screenRect, knockout: filled)
        }
    }

    private static func drawBadge(_ text: String, centeredIn rect: NSRect, knockout: Bool) {
        let baseFont = NSFont.systemFont(ofSize: 8.4, weight: knockout ? .heavy : .bold)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded)
        let font = roundedDescriptor.flatMap { NSFont(descriptor: $0, size: 8.4) } ?? baseFont

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()

        let drawPoint = NSPoint(
            x: rect.midX - textSize.width / 2.0,
            y: rect.midY - textSize.height / 2.0 - 0.25
        )

        if knockout, let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationOut
            attributed.draw(at: drawPoint)
            ctx.restoreGraphicsState()
        } else {
            attributed.draw(at: drawPoint)
        }
    }

    private static func drawRevertGlyph(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 3.1

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 145,
            endAngle: -135,
            clockwise: true
        )
        arc.lineWidth = 1.3
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()

        // Наконечник стрелки отката (слева-сверху)
        let angleRad = 145.0 * .pi / 180.0
        let tip = NSPoint(
            x: center.x + radius * cos(angleRad),
            y: center.y + radius * sin(angleRad)
        )
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip.x - 0.4, y: tip.y + 2.0))
        arrow.line(to: tip)
        arrow.line(to: NSPoint(x: tip.x + 2.1, y: tip.y + 0.3))
        arrow.lineWidth = 1.25
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }
}
