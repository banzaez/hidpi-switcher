import CoreGraphics

/// Доменная модель физического или виртуального дисплея.
public struct DisplayDevice: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isMain: Bool
    public let isBuiltin: Bool
    public let vendorNumber: UInt32
    public let modelNumber: UInt32

    public init(
        id: CGDirectDisplayID,
        name: String,
        isMain: Bool,
        isBuiltin: Bool,
        vendorNumber: UInt32 = 0,
        modelNumber: UInt32 = 0
    ) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
    }

    /// Стабильный идентификатор модели монитора для сохранения настроек между сессиями.
    public var persistentIdentifier: String {
        "\(vendorNumber)-\(modelNumber)-\(isBuiltin ? 1 : 0)-\(id)"
    }
}

/// Доменная модель видеорежима CGS (без привязки к UI-форматированию).
public struct DisplayMode: Identifiable, Hashable, Sendable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let freq: Int
    public let density: Float
    public let isHiDPI: Bool

    public init(
        id: Int,
        width: Int,
        height: Int,
        freq: Int,
        density: Float,
        isHiDPI: Bool
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.freq = freq
        self.density = density
        self.isHiDPI = isHiDPI
    }

    /// Площадь в логических пикселях.
    public var area: Int {
        width * height
    }

    /// Длинная сторона экрана (корректно работает как для альбомной, так и для портретной ориентации).
    public var maxDimension: Int {
        max(width, height)
    }

    /// Приблизительное соотношение сторон (с точностью до сотых) для сопоставления режимов.
    public var aspectRatioBucket: Int {
        guard height > 0 else { return 0 }
        return Int((Double(width) / Double(height) * 100.0).rounded())
    }
}

/// Ключ уникальности режима по его геометрическим параметрам, частоте и признаку HiDPI.
public struct ModeKey: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let freq: Int
    public let isHiDPI: Bool

    public init(width: Int, height: Int, freq: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.freq = freq
        self.isHiDPI = isHiDPI
    }

    public init(mode: DisplayMode) {
        self.width = mode.width
        self.height = mode.height
        self.freq = mode.freq
        self.isHiDPI = mode.isHiDPI
    }
}

/// Ключ геометрии разрешения (без учёта частоты обновления) для группировки дублей по герцовке.
public struct ResolutionKey: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let isHiDPI: Bool

    public init(width: Int, height: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }

    public init(mode: DisplayMode) {
        self.width = mode.width
        self.height = mode.height
        self.isHiDPI = mode.isHiDPI
    }
}

/// Сформированный каталог режимов для выбранного дисплея.
public struct ModeCatalog: Equatable, Sendable {
    /// Полный список дедуплицированных режимов (включая все частоты обновления).
    public let availableModes: [DisplayMode]
    /// Сгруппированные по геометрии режимы HiDPI (2x) для меню разрешений.
    public let hidpiModes: [DisplayMode]
    /// Сгруппированные по геометрии стандартные режимы (1x) для меню разрешений.
    public let standardModes: [DisplayMode]
    /// Доступные частоты обновления для текущего активного разрешения.
    public let availableRefreshRates: [DisplayMode]
    /// Текущий активный режим.
    public let currentMode: DisplayMode?

    public init(
        availableModes: [DisplayMode] = [],
        hidpiModes: [DisplayMode] = [],
        standardModes: [DisplayMode] = [],
        availableRefreshRates: [DisplayMode] = [],
        currentMode: DisplayMode? = nil
    ) {
        self.availableModes = availableModes
        self.hidpiModes = hidpiModes
        self.standardModes = standardModes
        self.availableRefreshRates = availableRefreshRates
        self.currentMode = currentMode
    }
}
