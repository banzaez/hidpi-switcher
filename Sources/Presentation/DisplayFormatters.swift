import Foundation

extension DisplayDevice {
    /// Заголовок экрана для меню выбора.
    var menuTitle: String {
        if isBuiltin {
            return "\(name) (Встроенный)"
        }
        return name
    }
}

extension DisplayMode {
    /// Форматированное название режима для подменю разрешений.
    var menuTitle: String {
        let tag = isHiDPI ? " [Retina 2x]" : " [1x]"
        let hz = freq > 0 ? " @ \(freq)Hz" : ""
        return "\(width) × \(height)\(tag)\(hz)"
    }

    /// Форматированное название для меню выбора частоты обновления.
    var refreshRateTitle: String {
        freq > 0 ? "\(freq) Hz" : "Стандартная"
    }

    /// Форматированное название для списка избранных пресетов.
    var favoriteTitle: String {
        let tag = isHiDPI ? " [2x]" : " [1x]"
        let hz = freq > 0 ? " @ \(freq)Hz" : ""
        return "★ \(width) × \(height)\(tag)\(hz)"
    }

    /// Краткое описание текущего режима для шапки меню.
    var statusSubtitle: String {
        let hz = freq > 0 ? " (@ \(freq)Hz)" : ""
        return isHiDPI
            ? "✓ Retina 2x HiDPI\(hz)"
            : "○ Стандартный 1x\(hz)"
    }
}
