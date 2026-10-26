import Foundation

/// Чистый доменный сервис фильтрации, дедупликации, группировки по частотам и подбора видеорежимов.
public enum ModeResolver {
    /// Минимальный размер длинной стороны экрана по умолчанию (поддерживает и альбомную, и портретную ориентацию).
    public static let defaultMinimumLongEdge = 1280

    /// Строит дедуплицированный, сгруппированный по разрешениям и отсортированный каталог режимов.
    public static func buildCatalog(
        rawModes: [DisplayMode],
        currentModeID: Int,
        minimumLongEdge: Int = defaultMinimumLongEdge
    ) -> ModeCatalog {
        var uniqueModes: [DisplayMode] = []
        uniqueModes.reserveCapacity(rawModes.count)

        var indexByKey: [ModeKey: Int] = [:]
        indexByKey.reserveCapacity(rawModes.count)

        var current: DisplayMode?

        for entry in rawModes {
            let key = ModeKey(mode: entry)
            if let existingIndex = indexByKey[key] {
                // Если среди дубликатов попался активный режим системы — сохраняем именно его ID
                if entry.id == currentModeID {
                    uniqueModes[existingIndex] = entry
                }
            } else {
                indexByKey[key] = uniqueModes.count
                uniqueModes.append(entry)
            }

            if entry.id == currentModeID {
                current = entry
            }
        }

        uniqueModes.sort { lhs, rhs in
            if lhs.isHiDPI != rhs.isHiDPI {
                return lhs.isHiDPI && !rhs.isHiDPI
            }
            if lhs.area != rhs.area {
                return lhs.area > rhs.area
            }
            if lhs.freq != rhs.freq {
                return lhs.freq > rhs.freq
            }
            return lhs.width > rhs.width
        }

        // Группируем по (width, height, isHiDPI), чтобы не засорять меню дублями 60/120/144Hz.
        // Для каждого разрешения выбираем:
        // 1) активный режим (если это текущее разрешение),
        // 2) режим с частотой текущего режима (если доступен),
        // 3) режим с максимальной частотой (первый в отсортированном списке).
        let preferredFreq = current?.freq
        var groupedByResolution: [ResolutionKey: DisplayMode] = [:]
        var orderedResolutionKeys: [ResolutionKey] = []

        for mode in uniqueModes where mode.maxDimension >= minimumLongEdge {
            let resKey = ResolutionKey(mode: mode)
            if let existing = groupedByResolution[resKey] {
                if mode.id == currentModeID {
                    groupedByResolution[resKey] = mode
                } else if existing.id != currentModeID,
                          let preferredFreq,
                          mode.freq == preferredFreq,
                          existing.freq != preferredFreq {
                    groupedByResolution[resKey] = mode
                }
            } else {
                groupedByResolution[resKey] = mode
                orderedResolutionKeys.append(resKey)
            }
        }

        var hidpi: [DisplayMode] = []
        var standard: [DisplayMode] = []
        hidpi.reserveCapacity(orderedResolutionKeys.count)
        standard.reserveCapacity(orderedResolutionKeys.count)

        for key in orderedResolutionKeys {
            guard let representative = groupedByResolution[key] else { continue }
            if representative.isHiDPI {
                hidpi.append(representative)
            } else {
                standard.append(representative)
            }
        }

        // Все доступные частоты обновления для текущего активного разрешения
        let refreshRates: [DisplayMode]
        if let current {
            refreshRates = uniqueModes.filter {
                $0.width == current.width &&
                $0.height == current.height &&
                $0.isHiDPI == current.isHiDPI
            }
        } else {
            refreshRates = []
        }

        return ModeCatalog(
            availableModes: uniqueModes,
            hidpiModes: hidpi,
            standardModes: standard,
            availableRefreshRates: refreshRates,
            currentMode: current
        )
    }

    /// Находит конкретный режим в каталоге по сохранённому ключу `ModeKey`.
    public static func findMode(
        matching key: ModeKey,
        in modes: [DisplayMode]
    ) -> DisplayMode? {
        if let exact = modes.first(where: { ModeKey(mode: $0) == key }) {
            return exact
        }
        // Фолбэк: то же разрешение и тип HiDPI с максимальной доступной частотой
        return modes.first(where: {
            $0.width == key.width && $0.height == key.height && $0.isHiDPI == key.isHiDPI
        })
    }

    /// Выбирает следующий избранный режим по кругу (для глобального хоткея переключения пресетов).
    public static func nextFavoriteMode(
        from current: DisplayMode?,
        favorites: [ModeKey],
        in modes: [DisplayMode]
    ) -> DisplayMode? {
        let resolvedFavorites = favorites.compactMap { findMode(matching: $0, in: modes) }
        guard !resolvedFavorites.isEmpty else { return nil }
        guard let current else { return resolvedFavorites.first }

        let currentKey = ModeKey(mode: current)
        if let idx = resolvedFavorites.firstIndex(where: { ModeKey(mode: $0) == currentKey }) {
            let nextIdx = (idx + 1) % resolvedFavorites.count
            return resolvedFavorites[nextIdx]
        }
        return resolvedFavorites.first
    }

    /// Подбирает оптимальный режим при переключении тумблера HiDPI (1x <-> 2x).
    public static func findToggleTarget(
        from current: DisplayMode,
        in modes: [DisplayMode]
    ) -> DisplayMode? {
        let targetHiDPI = !current.isHiDPI
        let candidates = modes.filter { $0.isHiDPI == targetHiDPI }
        guard !candidates.isEmpty else { return nil }

        // 1. Точное совпадение логической геометрии и частоты обновления
        if let exact = candidates.first(where: {
            $0.width == current.width && $0.height == current.height && $0.freq == current.freq
        }) {
            return exact
        }

        // 2. Та же логическая геометрия (выбираем ближайшую частоту, при равенстве — более высокую)
        let sameGeometry = candidates.filter {
            $0.width == current.width && $0.height == current.height
        }
        if let bestGeometryMatch = sameGeometry.min(by: {
            let d0 = abs($0.freq - current.freq)
            let d1 = abs($1.freq - current.freq)
            return d0 != d1 ? d0 < d1 : $0.freq > $1.freq
        }) {
            return bestGeometryMatch
        }

        // 3. Парный физический Retina-режим (например, 3840×2160 1x -> 1920×1080 2x или наоборот)
        let scaledWidth = targetHiDPI ? current.width / 2 : current.width * 2
        let scaledHeight = targetHiDPI ? current.height / 2 : current.height * 2
        let scaledMatches = candidates.filter {
            $0.width == scaledWidth && $0.height == scaledHeight
        }
        if let bestScaled = scaledMatches.min(by: {
            let d0 = abs($0.freq - current.freq)
            let d1 = abs($1.freq - current.freq)
            return d0 != d1 ? d0 < d1 : $0.freq > $1.freq
        }) {
            return bestScaled
        }

        // 4. То же соотношение сторон и ближайшая площадь с сохранением частоты
        let sameAspect = candidates.filter { $0.aspectRatioBucket == current.aspectRatioBucket }
        let pool = sameAspect.isEmpty ? candidates : sameAspect

        return pool.min { lhs, rhs in
            let areaDiff0 = abs(lhs.area - current.area)
            let areaDiff1 = abs(rhs.area - current.area)
            if areaDiff0 != areaDiff1 {
                return areaDiff0 < areaDiff1
            }
            let freqDiff0 = abs(lhs.freq - current.freq)
            let freqDiff1 = abs(rhs.freq - current.freq)
            return freqDiff0 != freqDiff1 ? freqDiff0 < freqDiff1 : lhs.freq > rhs.freq
        }
    }
}
