import CoreGraphics
import Foundation
import IOKit

// Private Apple Silicon DDC/I2C entry points, as used by m1ddc and MonitorControl.
@_silgen_name("IOAVServiceCreateWithService")
private func avServiceCreate(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func avServiceRead(
    _ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func avServiceWrite(
    _ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32
) -> IOReturn

public final class NativeDDCTransport: DDCTransport {
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private let service: CFTypeRef

    init(service: CFTypeRef) { self.service = service }

    public func write(_ bytes: [UInt8]) -> Bool {
        var buffer = bytes
        let status = buffer.withUnsafeMutableBytes {
            avServiceWrite(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
        }
        return status == kIOReturnSuccess
    }

    public func read(count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes {
            avServiceRead(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32(count))
        }
        return status == kIOReturnSuccess ? buffer : nil
    }

    /// The DDC channel for a display, matched by the EDID serial number macOS reports for it.
    /// Returns nil rather than guessing when the serial is missing or shared by several channels.
    public static func forDisplay(_ id: CGDirectDisplayID) -> NativeDDCTransport? {
        let serial = CGDisplaySerialNumber(id)
        guard serial != 0 else { return nil }
        let matches = externalChannels().filter { $0.serial == serial }
        guard matches.count == 1 else { return nil }
        return NativeDDCTransport(service: matches[0].service)
    }

    /// External DCPAVServiceProxy entries in IOService-plane order; each follows its display's framebuffer.
    static func externalChannels() -> [(service: CFTypeRef, serial: UInt32?)] {
        var iterator = io_iterator_t()
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, options, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [(service: CFTypeRef, serial: UInt32?)] = []
        var lastSerial: UInt32?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name == "IOMobileFramebufferShim" || name == "AppleCLCD2" {
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                if let serial = product?["SerialNumber"] as? NSNumber { lastSerial = serial.uint32Value }
            } else if name == "DCPAVServiceProxy", property(entry, "Location") as? String == "External" {
                if let service = avServiceCreate(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    result.append((service, lastSerial))
                }
                lastSerial = nil
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
