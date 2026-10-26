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

    /// Подбирает оптимальный набор логических HiDPI (2x) разрешений под соотношение сторон монитора.
    public static func recommendedResolutions(
        nativeWidth: Int,
        nativeHeight: Int
    ) -> [HiDPIResolutionPair] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }

        let ratio = Double(nativeWidth) / Double(nativeHeight)
        var pairs: [HiDPIResolutionPair] = []

        if abs(ratio - (21.0 / 9.0)) < 0.15 || (nativeWidth == 3440 && nativeHeight == 1440) {
            // 21:9 Ultrawide (3440×1440, 2560×1080, 3840×1600)
            pairs = [
                HiDPIResolutionPair(logicalWidth: 3440, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 3008, logicalHeight: 1260),
                HiDPIResolutionPair(logicalWidth: 2752, logicalHeight: 1152),
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 858)
            ]
        } else if abs(ratio - (32.0 / 9.0)) < 0.2 {
            // 32:9 Super Ultrawide (5120×1440)
            pairs = [
                HiDPIResolutionPair(logicalWidth: 3840, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 3440, logicalHeight: 968),
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 720)
            ]
        } else if abs(ratio - (16.0 / 10.0)) < 0.06 {
            // 16:10 (2560×1600, 1920×1200)
            pairs = [
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1600),
                HiDPIResolutionPair(logicalWidth: 2304, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 1280),
                HiDPIResolutionPair(logicalWidth: 1920, logicalHeight: 1200),
                HiDPIResolutionPair(logicalWidth: 1680, logicalHeight: 1050)
            ]
        } else {
            // 16:9 QHD / 4K (2560×1440 и стандартные широкоформатные экраны)
            pairs = [
                HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1440),
                HiDPIResolutionPair(logicalWidth: 2304, logicalHeight: 1296),
                HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 1152),
                HiDPIResolutionPair(logicalWidth: 1920, logicalHeight: 1080),
                HiDPIResolutionPair(logicalWidth: 1600, logicalHeight: 900)
            ]
        }

        // Гарантируем, что нативное разрешение и пропорциональные шаги монитора присутствуют,
        // и не превышаем лимит текстуры виртуального фреймбуфера (7680px по ширине)
        let customSteps: [Double] = [1.0, 0.9, 0.8, 0.75]
        for scale in customSteps {
            let w = Int((Double(nativeWidth) * scale / 2.0).rounded()) * 2
            let h = Int((Double(nativeHeight) * scale / 2.0).rounded()) * 2
            let candidate = HiDPIResolutionPair(logicalWidth: w, logicalHeight: h)
            if w >= 1280, !pairs.contains(candidate) {
                pairs.append(candidate)
            }
        }

        return pairs
            .filter { $0.backingWidth <= 7680 && $0.backingHeight <= 4320 }
            .sorted { $0.logicalWidth * $0.logicalHeight > $1.logicalWidth * $1.logicalHeight }
    }

    /// Кодирует запись `scale-resolutions` (16 байт Big-Endian: width, height, scale=1, flags).
    public static func encodeScaleResolutionEntry(
        width: UInt32,
        height: UInt32,
        hiDPIFlag: UInt32 = 0x0020_0000
    ) -> Data {
        var words: [UInt32] = [
            width.bigEndian,
            height.bigEndian,
            UInt32(1).bigEndian,
            hiDPIFlag.bigEndian
        ]
        return Data(bytes: &words, count: words.count * MemoryLayout<UInt32>.size)
    }

    /// Формирует словарь Override Plist для сохранения в `/Library/Displays/Contents/Resources/Overrides/...`.
    public static func buildOverridePlistDictionary(
        device: DisplayDevice,
        resolutions: [HiDPIResolutionPair]
    ) -> [String: Any] {
        var scaleResolutions: [Data] = []
        scaleResolutions.reserveCapacity(resolutions.count * 2)

        for res in resolutions {
            // Запись 2x backing-буфера с флагом HiDPI (0x00200000) и парная запись логического размера
            scaleResolutions.append(
                encodeScaleResolutionEntry(
                    width: UInt32(res.backingWidth),
                    height: UInt32(res.backingHeight),
                    hiDPIFlag: 0x0020_0000
                )
            )
            scaleResolutions.append(
                encodeScaleResolutionEntry(
                    width: UInt32(res.logicalWidth),
                    height: UInt32(res.logicalHeight),
                    hiDPIFlag: 0x0020_0000
                )
            )
        }

        return [
            "DisplayProductName": "\(device.name) (HiDPI)",
            "DisplayVendorID": Int(device.vendorNumber),
            "DisplayProductID": Int(device.modelNumber),
            "scale-resolutions": scaleResolutions
        ]
    }
}
