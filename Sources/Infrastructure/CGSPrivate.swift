import CoreGraphics

// MARK: - Приватные функции CoreGraphics (SkyLight / CGS)

@_silgen_name("CGSGetCurrentDisplayMode")
private func CGSGetCurrentDisplayMode(
    _ display: CGDirectDisplayID,
    _ modeNum: UnsafeMutablePointer<Int32>
)

@_silgen_name("CGSGetNumberOfDisplayModes")
private func CGSGetNumberOfDisplayModes(
    _ display: CGDirectDisplayID,
    _ nModes: UnsafeMutablePointer<Int32>
)

@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
private func CGSGetDisplayModeDescriptionOfLength(
    _ display: CGDirectDisplayID,
    _ idx: Int32,
    _ mode: UnsafeMutableRawPointer,
    _ length: Int32
)

@_silgen_name("CGSConfigureDisplayMode")
private func CGSConfigureDisplayMode(
    _ config: CGDisplayConfigRef?,
    _ display: CGDirectDisplayID,
    _ modeNum: Int32
)

// MARK: - Бинарная раскладка CGSMode (0xD4 / буфер 0xDC)

/// Приватная структура описания видеорежима CGS.
/// Поле `density` располагается ровно по смещению `0xD0` (208 байт) и заканчивается на `0xD4` (212 байт).
/// Дополнительное поле `padding` доводит размер буфера до `0xDC` (220 байт) аналогично `union modes_D4`.
public struct CGSModeRaw: Sendable {
    public static let descriptionLength: Int32 = 0xD4
    public static let expectedBufferSize: Int = 0xDC

    public var mode: UInt32 = 0
    public var flags: UInt32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var depth: UInt32 = 0
    public var dc2: (
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0
    )
    public var dc3: UInt16 = 0
    public var freq: UInt16 = 0
    public var dc4: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    public var density: Float = 0
    public var padding: (UInt32, UInt32) = (0, 0)

    public init() {}
}

/// Низкоуровневый оберточный namespace без аллокаций в куче.
public enum CGSNative {
    public static func currentModeID(for displayID: CGDirectDisplayID) -> Int {
        var current: Int32 = -1
        CGSGetCurrentDisplayMode(displayID, &current)
        return Int(current)
    }

    public static func allModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        var count: Int32 = 0
        CGSGetNumberOfDisplayModes(displayID, &count)
        guard count > 0 else { return [] }

        var result: [DisplayMode] = []
        result.reserveCapacity(Int(count))

        for index in 0..<count {
            var raw = CGSModeRaw()
            withUnsafeMutablePointer(to: &raw) { ptr in
                CGSGetDisplayModeDescriptionOfLength(
                    displayID,
                    index,
                    UnsafeMutableRawPointer(ptr),
                    CGSModeRaw.descriptionLength
                )
            }

            let mode = DisplayMode(
                id: Int(raw.mode),
                width: Int(raw.width),
                height: Int(raw.height),
                freq: Int(raw.freq),
                density: raw.density,
                isHiDPI: raw.density >= 1.5
            )
            result.append(mode)
        }

        return result
    }

    @discardableResult
    public static func setDisplayMode(_ modeID: Int, for displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        CGSConfigureDisplayMode(config, displayID, Int32(modeID))

        // Применяем на время сессии: в случае неподдерживаемого сигнала перезагрузка сбросит режим.
        let status = CGCompleteDisplayConfiguration(config, .forSession)
        if status != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return true
    }
}
