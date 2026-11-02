import AppKit
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "VirtualHiDPIService")

// MARK: - Приватные @objc протоколы для прямого вызова CGVirtualDisplay без Objective-C файлов

@objc private protocol CGVirtualDisplayDescriptorObjC: NSObjectProtocol {
    init()
    var vendorID: UInt32 { get set }
    var productID: UInt32 { get set }
    var serialNum: UInt32 { get set }
    var name: String? { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var redPrimary: CGPoint { get set }
    var greenPrimary: CGPoint { get set }
    var bluePrimary: CGPoint { get set }
    var whitePoint: CGPoint { get set }
    func setDispatchQueue(_ queue: DispatchQueue)
}

@objc private protocol CGVirtualDisplayModeObjC: NSObjectProtocol {
    init(width: UInt32, height: UInt32, refreshRate: Double)
    var width: UInt32 { get }
    var height: UInt32 { get }
    var refreshRate: Double { get }
}

@objc private protocol CGVirtualDisplaySettingsObjC: NSObjectProtocol {
    init()
    var hiDPI: UInt32 { get set }
    var modes: [AnyObject] { get set }
}

@objc private protocol CGVirtualDisplayObjC: NSObjectProtocol {
    init?(descriptor: AnyObject)
    var displayID: CGDirectDisplayID { get }
    func applySettings(_ settings: AnyObject) -> Bool
}

/// Протокол управления виртуальным HiDPI-фреймбуфером (для QHD 2560×1440 / Ultrawide 3440×1440 на Apple Silicon).
@MainActor
public protocol VirtualHiDPIServiceProtocol: AnyObject {
    func isVirtualHiDPIActive(for physicalDisplayID: CGDirectDisplayID) -> Bool
    func virtualDisplayID(for physicalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID?
    func enableVirtualHiDPI(
        for device: DisplayDevice,
        nativeWidth: Int,
        nativeHeight: Int,
        refreshRate: Double
    ) -> CGDirectDisplayID?
    @discardableResult
    func disableVirtualHiDPI(for displayID: CGDirectDisplayID) -> CGDirectDisplayID?
    func disableAll()
}

/// Реализация виртуального HiDPI-фреймбуфера поверх `CGVirtualDisplay` и аппаратного зеркалирования CoreGraphics.
@MainActor
public final class LiveVirtualHiDPIService: VirtualHiDPIServiceProtocol {
    private struct ActiveSession {
        let physicalDisplayID: CGDirectDisplayID
        let virtualDisplayID: CGDirectDisplayID
        let virtualDisplayObject: AnyObject
    }

    private var sessionsByPhysicalID: [CGDirectDisplayID: ActiveSession] = [:]

    public init() {}

    public func isVirtualHiDPIActive(for physicalDisplayID: CGDirectDisplayID) -> Bool {
        if sessionsByPhysicalID[physicalDisplayID] != nil {
            return true
        }
        // Также проверяем, не является ли переданный ID уже самим виртуальным экраном активной сессии
        return sessionsByPhysicalID.values.contains { $0.virtualDisplayID == physicalDisplayID }
    }

    public func virtualDisplayID(for physicalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        sessionsByPhysicalID[physicalDisplayID]?.virtualDisplayID
    }

    public func enableVirtualHiDPI(
        for device: DisplayDevice,
        nativeWidth: Int,
        nativeHeight: Int,
        refreshRate: Double
    ) -> CGDirectDisplayID? {
        if let existing = sessionsByPhysicalID[device.id] {
            return existing.virtualDisplayID
        }

        guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else {
            log.error("Классы CGVirtualDisplay недоступны в текущей версии macOS")
            return nil
        }

        let resolutions = CustomHiDPISpec.recommendedResolutions(
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight
        )
        guard let maxRes = resolutions.first else { return nil }

        let descType = unsafeBitCast(descClass, to: CGVirtualDisplayDescriptorObjC.Type.self)
        let descriptor = descType.init()
        descriptor.vendorID = 0xF0F0
        descriptor.productID = device.modelNumber &+ 0x1000
        descriptor.serialNum = device.id
        descriptor.name = "\(device.name) (HiDPI)"
        descriptor.maxPixelsWide = UInt32(maxRes.backingWidth)
        descriptor.maxPixelsHigh = UInt32(maxRes.backingHeight)

        let physicalSize = CGDisplayScreenSize(device.id)
        if physicalSize.width > 0 && physicalSize.height > 0 {
            descriptor.sizeInMillimeters = physicalSize
        } else {
            descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        }

        // Стандартные координаты цветового охвата sRGB / Rec.709
        descriptor.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.setDispatchQueue(DispatchQueue.main)

        let modeType = unsafeBitCast(modeClass, to: CGVirtualDisplayModeObjC.Type.self)
        let targetHz = refreshRate >= 30 ? refreshRate : 60.0
        var virtualModes: [AnyObject] = []

        for pair in resolutions {
            let backingMode = modeType.init(
                width: UInt32(pair.backingWidth),
                height: UInt32(pair.backingHeight),
                refreshRate: targetHz
            )
            let logicalMode = modeType.init(
                width: UInt32(pair.logicalWidth),
                height: UInt32(pair.logicalHeight),
                refreshRate: targetHz
            )
            virtualModes.append(backingMode)
            virtualModes.append(logicalMode)
        }

        let settingsType = unsafeBitCast(settingsClass, to: CGVirtualDisplaySettingsObjC.Type.self)
        let settings = settingsType.init()
        settings.hiDPI = 1
        settings.modes = virtualModes

        let displayType = unsafeBitCast(displayClass, to: CGVirtualDisplayObjC.Type.self)
        guard let virtualDisplay = displayType.init(descriptor: descriptor),
              virtualDisplay.applySettings(settings) else {
            log.error("Не удалось инициализировать или применить настройки CGVirtualDisplay")
            return nil
        }

        let vDisplayID = virtualDisplay.displayID
        guard vDisplayID != 0, vDisplayID != kCGNullDirectDisplay else {
            log.error("CGVirtualDisplay вернул некорректный displayID")
            return nil
        }

        // Привязываем аппаратное зеркалирование физического монитора к виртуальному HiDPI-буферу
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return nil
        }
        CGConfigureDisplayMirrorOfDisplay(config, device.id, vDisplayID)
        let status = CGCompleteDisplayConfiguration(config, .forSession)
        if status != .success {
            CGCancelDisplayConfiguration(config)
            log.error("Ошибка включения аппаратного зеркалирования на CGVirtualDisplay: \(status.rawValue)")
            return nil
        }

        sessionsByPhysicalID[device.id] = ActiveSession(
            physicalDisplayID: device.id,
            virtualDisplayID: vDisplayID,
            virtualDisplayObject: virtualDisplay
        )
        log.notice("Виртуальный HiDPI-фреймбуфер активирован (physical: \(device.id) -> virtual: \(vDisplayID))")
        return vDisplayID
    }

    @discardableResult
    public func disableVirtualHiDPI(for displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let session = sessionsByPhysicalID[displayID]
            ?? sessionsByPhysicalID.values.first { $0.virtualDisplayID == displayID }
        guard let session else { return nil }

        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            CGConfigureDisplayMirrorOfDisplay(config, session.physicalDisplayID, kCGNullDirectDisplay)
            _ = CGCompleteDisplayConfiguration(config, .forSession)
        }

        sessionsByPhysicalID.removeValue(forKey: session.physicalDisplayID)
        log.notice("Виртуальный HiDPI-фреймбуфер отключён для монитора \(session.physicalDisplayID)")
        return session.physicalDisplayID
    }

    public func disableAll() {
        let keys = Array(sessionsByPhysicalID.keys)
        for key in keys {
            disableVirtualHiDPI(for: key)
        }
    }
}
