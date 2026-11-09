import Foundation

/// Пара логического разрешения (в поинтах) для генерации кастомных HiDPI-режимов (2x).
public struct HiDPIResolutionPair: Equatable, Hashable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int

    public var backingWidth: Int { logicalWidth * 2 }
    public var backingHeight: Int { logicalHeight * 2 }

    public init(logicalWidth: Int, logicalHeight: Int) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }
}

/// Чистый доменный генератор кастомных HiDPI-разрешений для QHD (2560×1440), Ultrawide (3440×1440) и 16:10 мониторов.
public enum CustomHiDPISpec {
    /// Базовый системный путь профилей мониторов macOS (доступен для записи с правами администратора при включённом SIP).
    public static let overridesBaseDirectory = "/Library/Displays/Contents/Resources/Overrides"

    /// Вычисляет путь к системному файлу Override Plist для конкретного монитора.
    public static func overrideFilePath(
        vendorID: UInt32,
        productID: UInt32,
        baseDirectory: String = overridesBaseDirectory
    ) -> String {
        let vendorHex = String(format: "%x", vendorID)
        let productHex = String(format: "%x", productID)
        return "\(baseDirectory)/DisplayVendorID-\(vendorHex)/DisplayProductID-\(productHex)"
    }

    /// Подбирает оптимальный набор логических HiDPI (2x) разрешений под соотношение сторон и ориентацию монитора.
    public static func recommendedResolutions(
        nativeWidth: Int,
        nativeHeight: Int
    ) -> [HiDPIResolutionPair] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }

        let isPortrait = nativeHeight > nativeWidth
        let landW = isPortrait ? nativeHeight : nativeWidth
        let landH = isPortrait ? nativeWidth : nativeHeight
        let ratio = Double(landW) / Double(landH)

        var landscapeCandidates: [HiDPIResolutionPair] = []

        if abs(ratio - (21.0 / 9.0)) < 0.15 || (landW == 3440 && landH == 1440) {
            // 21:9 Ultrawide (3440×1440, 2560×1080, 3840×1600)
            landscapeCandidates = [
                HiDPIResolutionPair(logicalWidth: 3440, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 3096, logicalHeight: 1296),
                HiDPIResolutionPair(logicalWidth: 3008, logicalHeight: 1260),
                HiDPIResolutionPair(logicalWidth: 2924, logicalHeight: 1224),
                HiDPIResolutionPair(logicalWidth: 2752, logicalHeight: 1152),
                HiDPIResolutionPair(logicalWidth: 2580, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 2408, logicalHeight: 1008),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 858),
                HiDPIResolutionPair(logicalWidth: 1720, logicalHeight: 720)
            ]
        } else if abs(ratio - (32.0 / 9.0)) < 0.2 {
            // 32:9 Super Ultrawide (5120×1440)
            landscapeCandidates = [
                HiDPIResolutionPair(logicalWidth: 3840, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 3440, logicalHeight: 968),
                HiDPIResolutionPair(logicalWidth: 3072, logicalHeight: 864),
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 720)
            ]
        } else if abs(ratio - (16.0 / 10.0)) < 0.06 {
            // 16:10 (2560×1600, 1920×1200)
            landscapeCandidates = [
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1600),
                HiDPIResolutionPair(logicalWidth: 2304, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 2176, logicalHeight: 1360),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 1280),
                HiDPIResolutionPair(logicalWidth: 1920, logicalHeight: 1200),
                HiDPIResolutionPair(logicalWidth: 1680, logicalHeight: 1050)
            ]
        } else {
            // 16:9 QHD / 4K (2560×1440 и стандартные широкоформатные экраны)
            landscapeCandidates = [
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 2304, logicalHeight: 1296),
                HiDPIResolutionPair(logicalWidth: 2176, logicalHeight: 1224),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 1152),
                HiDPIResolutionPair(logicalWidth: 1920, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 1792, logicalHeight: 1008),
                HiDPIResolutionPair(logicalWidth: 1600, logicalHeight: 900)
            ]
        }

        // Оставляем только пресеты не больше нативного разрешения и близкие по соотношению сторон
        landscapeCandidates = landscapeCandidates.filter { pair in
            guard pair.logicalWidth <= landW, pair.logicalHeight <= landH else { return false }
            let pairRatio = Double(pair.logicalWidth) / Double(pair.logicalHeight)
            return abs(pairRatio - ratio) <= 0.03
        }

        // Гарантируем, что нативное разрешение и точные пропорциональные шаги монитора присутствуют
        let customSteps: [Double] = [1.0, 0.9, 0.85, 0.8, 0.75, 0.7, 0.6, 0.5]
        for scale in customSteps {
            let w = Int((Double(landW) * scale / 2.0).rounded()) * 2
            let h = Int((Double(landH) * scale / 2.0).rounded()) * 2
            let candidate = HiDPIResolutionPair(logicalWidth: w, logicalHeight: h)
            if w >= 1280, h > 0, !landscapeCandidates.contains(candidate) {
                landscapeCandidates.append(candidate)
            }
        }

        let pairs: [HiDPIResolutionPair] = landscapeCandidates.map { pair in
            isPortrait
                ? HiDPIResolutionPair(logicalWidth: pair.logicalHeight, logicalHeight: pair.logicalWidth)
                : pair
        }

        // Не превышаем аппаратный лимит текстуры виртуального фреймбуфера (7680×4320 с учётом ориентации)
        return pairs
            .filter {
                max($0.backingWidth, $0.backingHeight) <= 7680 &&
                min($0.backingWidth, $0.backingHeight) <= 4320
            }
            .sorted { $0.logicalWidth * $0.logicalHeight > $1.logicalWidth * $1.logicalHeight }
    }

    /// Подбирает оптимальное дефолтное HiDPI-разрешение с настоящим суперсэмплингом (~80% от нативного, 1.25x физических пикселей на поинт),
    /// например `2752×1152` для `3440×1440` или `2048×1152` для `2560×1440`.
    public static func preferredHiDPIResolution(
        nativeWidth: Int,
        nativeHeight: Int
    ) -> HiDPIResolutionPair? {
        let list = recommendedResolutions(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        guard !list.isEmpty else { return nil }

        let targetWidth = Double(nativeWidth) * 0.8
        let nonNative = list.filter { $0.logicalWidth < nativeWidth || $0.logicalHeight < nativeHeight }
        if let best = nonNative.min(by: {
            abs(Double($0.logicalWidth) - targetWidth) < abs(Double($1.logicalWidth) - targetWidth)
        }) {
            return best
        }
        return list.first
    }

    /// Кодирует базовую 8-байтную запись `scale-resolutions` (Big-Endian: width, height).
    public static func encodeBaseResolutionEntry(
        width: UInt32,
        height: UInt32
    ) -> Data {
        let words: (UInt32, UInt32) = (
            width.bigEndian,
            height.bigEndian
        )
        return withUnsafeBytes(of: words) { Data($0) }
    }

    /// Кодирует запись `scale-resolutions` (16 байт Big-Endian: width, height, scale, flags) без аллокации промежуточного массива.
    public static func encodeScaleResolutionEntry(
        width: UInt32,
        height: UInt32,
        scale: UInt32 = 1,
        hiDPIFlag: UInt32 = 0x0020_0000
    ) -> Data {
        let words: (UInt32, UInt32, UInt32, UInt32) = (
            width.bigEndian,
            height.bigEndian,
            scale.bigEndian,
            hiDPIFlag.bigEndian
        )
        return withUnsafeBytes(of: words) { Data($0) }
    }

    /// Формирует словарь Override Plist для сохранения в `/Library/Displays/Contents/Resources/Overrides/...`.
    public static func buildOverridePlistDictionary(
        device: DisplayDevice,
        resolutions: [HiDPIResolutionPair]
    ) -> [String: Any] {
        var scaleResolutions: [Data] = []
        scaleResolutions.reserveCapacity(resolutions.count * 5)

        // 1. Базовые 8-байтные записи (backing + logical), как в современных профилях Apple (DisplayProductID-ae37/ae47)
        for res in resolutions {
            scaleResolutions.append(
                encodeBaseResolutionEntry(
                    width: UInt32(res.backingWidth),
                    height: UInt32(res.backingHeight)
                )
            )
            scaleResolutions.append(
                encodeBaseResolutionEntry(
                    width: UInt32(res.logicalWidth),
                    height: UInt32(res.logicalHeight)
                )
            )
        }

        // 2. Классические 16-байтные записи с флагом HiDPI (scale=1, flags=0x00200000)
        for res in resolutions {
            scaleResolutions.append(
                encodeScaleResolutionEntry(
                    width: UInt32(res.backingWidth),
                    height: UInt32(res.backingHeight),
                    scale: 1,
                    hiDPIFlag: 0x0020_0000
                )
            )
            scaleResolutions.append(
                encodeScaleResolutionEntry(
                    width: UInt32(res.logicalWidth),
                    height: UInt32(res.logicalHeight),
                    scale: 1,
                    hiDPIFlag: 0x0020_0000
                )
            )
        }

        // 3. Записи синтеза масштабированных Retina-режимов (scale=9, flags=0x00a00000)
        for res in resolutions {
            scaleResolutions.append(
                encodeScaleResolutionEntry(
                    width: UInt32(res.backingWidth),
                    height: UInt32(res.backingHeight),
                    scale: 9,
                    hiDPIFlag: 0x00A0_0000
                )
            )
        }

        let cleanName = device.name.replacingOccurrences(of: " (HiDPI)", with: "")
        return [
            "DisplayProductName": "\(cleanName) (HiDPI)",
            "DisplayVendorID": Int(device.vendorNumber),
            "DisplayProductID": Int(device.modelNumber),
            "scale-resolutions": scaleResolutions
        ]
    }
}
