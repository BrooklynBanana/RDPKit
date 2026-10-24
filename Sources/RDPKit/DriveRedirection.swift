import Darwin
import Foundation

// Connection Manager: Laufwerksumleitung (MS-RDPEFS 2.2.3.3, Dateisystem-IRPs) gegen einen Ordner auf dem Mac.
// Dateiinformationen nach MS-FSCC; Aufbau der Antworten wie FreeRDP (channels/drive/client).

enum RDPIRPMajor {
    static let create: UInt32 = 0x00
    static let close: UInt32 = 0x02
    static let read: UInt32 = 0x03
    static let write: UInt32 = 0x04
    static let queryInformation: UInt32 = 0x05
    static let setInformation: UInt32 = 0x06
    static let queryVolumeInformation: UInt32 = 0x0A
    static let setVolumeInformation: UInt32 = 0x0B
    static let directoryControl: UInt32 = 0x0C
    static let deviceControl: UInt32 = 0x0E
    static let lockControl: UInt32 = 0x11
}

enum RDPIRPMinor {
    static let queryDirectory: UInt32 = 0x01
    static let notifyChangeDirectory: UInt32 = 0x02
}

extension RDPNTStatus {
    static let unsuccessful: UInt32 = 0xC000_0001
    static let noSuchFile: UInt32 = 0xC000_000F
    static let accessDenied: UInt32 = 0xC000_0022
    static let objectNameNotFound: UInt32 = 0xC000_0034
    static let objectNameCollision: UInt32 = 0xC000_0035
    static let objectPathNotFound: UInt32 = 0xC000_003A
    static let diskFull: UInt32 = 0xC000_007F
    static let fileIsADirectory: UInt32 = 0xC000_00BA
    static let notADirectory: UInt32 = 0xC000_0103
    static let directoryNotEmpty: UInt32 = 0xC000_0101
    static let invalidHandle: UInt32 = 0xC000_0008
    static let invalidParameter: UInt32 = 0xC000_000D
    static let noMoreFiles: UInt32 = 0x8000_0006
}

private enum FileAttribute {
    static let readOnly: UInt32 = 0x01
    static let hidden: UInt32 = 0x02
    static let directory: UInt32 = 0x10
    static let archive: UInt32 = 0x20
    static let normal: UInt32 = 0x80
}

private enum CreateDisposition {
    static let supersede: UInt32 = 0
    static let open: UInt32 = 1
    static let create: UInt32 = 2
    static let openIf: UInt32 = 3
    static let overwrite: UInt32 = 4
    static let overwriteIf: UInt32 = 5
}

private enum CreateOption {
    static let directoryFile: UInt32 = 0x0000_0001
    static let nonDirectoryFile: UInt32 = 0x0000_0040
    static let deleteOnClose: UInt32 = 0x0000_1000
}

private enum CreateResult {
    static let superseded: UInt8 = 0
    static let opened: UInt8 = 1
    static let created: UInt8 = 2
    static let overwritten: UInt8 = 3
}

/// FileInformationClass / FsInformationClass (MS-FSCC 2.4, 2.5)
private enum InformationClass {
    static let directory: UInt32 = 1
    static let fullDirectory: UInt32 = 2
    static let bothDirectory: UInt32 = 3
    static let basic: UInt32 = 4
    static let standard: UInt32 = 5
    static let names: UInt32 = 12
    static let attributeTag: UInt32 = 35
    static let rename: UInt32 = 10
    static let disposition: UInt32 = 13
    static let allocation: UInt32 = 19
    static let endOfFile: UInt32 = 20

    static let fsVolume: UInt32 = 1
    static let fsSize: UInt32 = 3
    static let fsDevice: UInt32 = 4
    static let fsAttribute: UInt32 = 5
    static let fsFullSize: UInt32 = 7
}

/// Angaben zu einer Datei bzw. einem Ordner, wie sie Windows erwartet.
struct RDPDriveFileInfo: Equatable, Sendable {
    var name: String
    var isDirectory: Bool
    var size: UInt64
    var creationTime: UInt64
    var accessTime: UInt64
    var writeTime: UInt64
    var changeTime: UInt64
    var attributes: UInt32

    /// FILETIME: 100-ns-Schritte seit 1.1.1601.
    static func fileTime(_ spec: timespec) -> UInt64 {
        let seconds = Int64(spec.tv_sec) + 11_644_473_600
        guard seconds > 0 else { return 0 }
        return UInt64(seconds) * 10_000_000 + UInt64(max(0, spec.tv_nsec) / 100)
    }

    static func load(_ url: URL, name: String) -> RDPDriveFileInfo? {
        var info = stat()
        guard lstat(url.path, &info) == 0 || stat(url.path, &info) == 0 else { return nil }
        // Links folgen (Ordner-Links wie Ordner zeigen)
        if info.st_mode & S_IFMT == S_IFLNK { _ = stat(url.path, &info) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        var attributes: UInt32 = isDirectory ? FileAttribute.directory : FileAttribute.archive
        if name.hasPrefix("."), name != ".", name != ".." { attributes |= FileAttribute.hidden }
        if access(url.path, W_OK) != 0 { attributes |= FileAttribute.readOnly }
        return RDPDriveFileInfo(
            name: name,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : UInt64(max(0, info.st_size)),
            creationTime: fileTime(info.st_birthtimespec),
            accessTime: fileTime(info.st_atimespec),
            writeTime: fileTime(info.st_mtimespec),
            changeTime: fileTime(info.st_ctimespec),
            attributes: attributes
        )
    }

    var allocationSize: UInt64 { (size + 4095) / 4096 * 4096 }
}

/// Ein umgeleiteter Ordner: bedient die Datei-IRPs des Servers. Nicht threadsicher – Aufrufe nacheinander
/// (die Sitzung nutzt eine eigene serielle Warteschlange).
final class RDPDriveDevice: @unchecked Sendable {
    private struct OpenFile {
        var url: URL
        var path: String
        var isDirectory: Bool
        var handle: FileHandle?
        /// Die geöffnete `handle` kann schreiben (erst beim ersten Schreiben zum Schreiben geöffnet).
        var handleWritable = false
        var listing: [RDPDriveFileInfo]?
        var listingIndex = 0
        var deleteOnClose = false
    }

    let deviceID: UInt32
    let name: String
    let root: URL
    private var files: [UInt32: OpenFile] = [:]
    private var nextFileID: UInt32 = 1

    init(deviceID: UInt32, name: String, root: URL) {
        self.deviceID = deviceID
        self.name = name
        self.root = root.standardizedFileURL
    }

    /// Antwort (DR_DEVICE_IOCOMPLETION); `nil` = keine Antwort (derzeit nicht genutzt).
    func handle(_ request: RDPDeviceIORequest) -> Data? {
        var body = ByteCursor(request.body)
        do {
            switch request.majorFunction {
            case RDPIRPMajor.create:
                return try create(request, body: &body)
            case RDPIRPMajor.close:
                close(request.fileID)
                return completion(request, status: RDPNTStatus.success, Data(count: 5))
            case RDPIRPMajor.read:
                return try read(request, body: &body)
            case RDPIRPMajor.write:
                return try write(request, body: &body)
            case RDPIRPMajor.queryInformation:
                return try queryInformation(request, body: &body)
            case RDPIRPMajor.queryVolumeInformation:
                return try queryVolume(request, body: &body)
            case RDPIRPMajor.directoryControl:
                // Änderungsbenachrichtigung nicht unterstützt (wie FreeRDP) – der Explorer liest dann bei Bedarf neu.
                if request.minorFunction == RDPIRPMinor.notifyChangeDirectory {
                    return completion(request, status: RDPNTStatus.notSupported, uint32(0))
                }
                return try queryDirectory(request, body: &body)
            case RDPIRPMajor.deviceControl:
                return completion(request, status: RDPNTStatus.success, uint32(0))
            case RDPIRPMajor.lockControl:
                return completion(request, status: RDPNTStatus.success, Data(count: 5))
            case RDPIRPMajor.setInformation:
                return try setInformation(request, body: &body)
            default:
                return completion(request, status: RDPNTStatus.notSupported, uint32(0))
            }
        } catch {
            return completion(request, status: RDPNTStatus.invalidParameter, uint32(0))
        }
    }

    func closeAll() {
        for id in Array(files.keys) { close(id) }
    }

    // MARK: Pfade

    /// `\Ordner\Datei` relativ zum freigegebenen Ordner; `..` wird abgelehnt (nicht aus dem Ordner heraus).
    /// Links im Mac-Ordner dürfen ebenfalls nicht hinausführen: Geprüft wird auch der Pfad mit aufgelösten Links
    /// (Windows kann selbst keine anlegen, im gewählten Ordner können aber welche liegen).
    func resolve(_ windowsPath: String) -> URL? {
        let parts = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = parts.reduce(root) { $0.appending(path: $1) }
        let standardized = url.standardizedFileURL
        guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else { return nil }
        guard let realRoot = Self.realPath(root), let real = Self.realPath(standardized),
              real == realRoot || real.hasPrefix(realRoot == "/" ? "/" : realRoot + "/") else { return nil }
        return standardized
    }

    /// Pfad mit aufgelösten Links; noch nicht vorhandene Teile werden angehängt. `nil` bei einem Link ohne Ziel
    /// (sein Ziel könnte außerhalb angelegt werden).
    static func realPath(_ url: URL) -> String? {
        var existing = url.path
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                guard !missing.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + missing.reversed().joined(separator: "/")
            }
            var info = stat()
            guard errno == ENOENT, lstat(existing, &info) != 0, existing != "/" else { return nil }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }

    private static func readPath(_ body: inout ByteCursor, length: UInt32) throws -> String {
        let data = try body.readData(count: Int(length))
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let unit = UInt16(data[index]) | UInt16(data[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Create / Close

    private func create(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let desiredAccess = try body.readLittleEndianUInt32()
        _ = try body.readLittleEndianUInt64()   // AllocationSize
        _ = try body.readLittleEndianUInt32()   // FileAttributes
        _ = try body.readLittleEndianUInt32()   // SharedAccess
        let disposition = try body.readLittleEndianUInt32()
        let options = try body.readLittleEndianUInt32()
        let pathLength = try body.readLittleEndianUInt32()
        let path = try Self.readPath(&body, length: pathLength)

        func fail(_ status: UInt32) -> Data {
            completion(request, status: status, uint32(0) + Data([0]))
        }
        guard let url = resolve(path) else { return fail(RDPNTStatus.accessDenied) }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let parentExists = manager.fileExists(atPath: url.deletingLastPathComponent().path)
        let wantsDirectory = options & CreateOption.directoryFile != 0
        var result = CreateResult.opened

        if exists, isDirectory.boolValue || wantsDirectory {
            guard isDirectory.boolValue else { return fail(RDPNTStatus.notADirectory) }
            guard options & CreateOption.nonDirectoryFile == 0 else { return fail(RDPNTStatus.fileIsADirectory) }
            guard disposition != CreateDisposition.create else { return fail(RDPNTStatus.objectNameCollision) }
        } else if wantsDirectory {
            guard parentExists else { return fail(RDPNTStatus.objectPathNotFound) }
            guard disposition == CreateDisposition.create || disposition == CreateDisposition.openIf else {
                return fail(RDPNTStatus.objectNameNotFound)
            }
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                return fail(Self.status(for: error))
            }
            result = CreateResult.created
        } else {
            switch disposition {
            case CreateDisposition.open:
                guard exists else { return fail(parentExists ? RDPNTStatus.objectNameNotFound : RDPNTStatus.objectPathNotFound) }
            case CreateDisposition.create:
                guard !exists else { return fail(RDPNTStatus.objectNameCollision) }
            case CreateDisposition.overwrite:
                guard exists else { return fail(RDPNTStatus.objectNameNotFound) }
            case CreateDisposition.supersede, CreateDisposition.openIf, CreateDisposition.overwriteIf:
                break
            default:
                return fail(RDPNTStatus.invalidParameter)
            }
            guard exists || parentExists else { return fail(RDPNTStatus.objectPathNotFound) }
            let shouldTruncate = exists && [CreateDisposition.supersede, CreateDisposition.overwrite,
                                            CreateDisposition.overwriteIf].contains(disposition)
            if !exists {
                guard manager.createFile(atPath: url.path, contents: nil) else {
                    return fail(access(url.deletingLastPathComponent().path, W_OK) != 0
                        ? RDPNTStatus.accessDenied : RDPNTStatus.unsuccessful)
                }
                result = CreateResult.created
            } else if shouldTruncate {
                guard truncate(url.path, 0) == 0 else { return fail(Self.status(errno: errno)) }
                result = disposition == CreateDisposition.supersede ? CreateResult.superseded : CreateResult.overwritten
            }
        }

        _ = desiredAccess   // Rechte prüft das Dateisystem beim Öffnen zum Lesen bzw. Schreiben
        let fileID = nextFileID
        nextFileID &+= 1
        files[fileID] = OpenFile(url: url, path: path, isDirectory: exists ? isDirectory.boolValue : wantsDirectory,
                                 handle: nil, deleteOnClose: options & CreateOption.deleteOnClose != 0)
        return completion(request, status: RDPNTStatus.success, uint32(fileID) + Data([result]))
    }

    private func close(_ fileID: UInt32) {
        guard let file = files.removeValue(forKey: fileID) else { return }
        try? file.handle?.close()
        // Nur die Datei bzw. einen leeren Ordner – Windows löscht Ordnerinhalte vorher selbst, Datei für Datei.
        if file.deleteOnClose { _ = file.isDirectory ? rmdir(file.url.path) : unlink(file.url.path) }
    }

    // MARK: Set Information (Umbenennen, Löschen, Größe, Zeitstempel)

    private func setInformation(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let infoClass = try body.readLittleEndianUInt32()
        let length = try body.readLittleEndianUInt32()
        _ = try body.readData(count: 24)   // Padding
        let buffer = try body.readData(count: Int(length))
        var input = ByteCursor(buffer)
        func reply(_ status: UInt32) -> Data { completion(request, status: status, uint32(length)) }
        guard var file = files[request.fileID] else { return reply(RDPNTStatus.invalidHandle) }

        switch infoClass {
        case InformationClass.basic:
            guard length >= 36 else { return reply(RDPNTStatus.invalidParameter) }
            _ = try input.readLittleEndianUInt64()   // CreationTime (macOS: nicht setzbar)
            let accessTime = try input.readLittleEndianUInt64()
            let writeTime = try input.readLittleEndianUInt64()
            _ = try input.readLittleEndianUInt64()   // ChangeTime
            // Zeitstempel setzen, 0 = unverändert; Attribute (Schreibschutz …) übernimmt der Mac nicht.
            var times = [Darwin.timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), Darwin.timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
            if let spec = Self.unixTime(fileTime: accessTime) { times[0] = spec }
            if let spec = Self.unixTime(fileTime: writeTime) { times[1] = spec }
            guard utimensat(AT_FDCWD, file.url.path, &times, 0) == 0 else { return reply(Self.status(errno: errno)) }
            return reply(RDPNTStatus.success)

        case InformationClass.endOfFile, InformationClass.allocation:
            guard length >= 8 else { return reply(RDPNTStatus.invalidParameter) }
            let size = try input.readLittleEndianUInt64()
            guard !file.isDirectory else { return reply(RDPNTStatus.fileIsADirectory) }
            // Belegte Größe kleiner als die Datei kürzt sie (MS-FSCC 2.4.4); größer ändert nichts.
            if infoClass == InformationClass.allocation {
                let current = RDPDriveFileInfo.load(file.url, name: file.url.lastPathComponent)?.size ?? 0
                guard size < current else { return reply(RDPNTStatus.success) }
            }
            try? file.handle?.synchronize()
            guard truncate(file.url.path, off_t(clamping: size)) == 0 else { return reply(Self.status(errno: errno)) }
            return reply(RDPNTStatus.success)

        case InformationClass.disposition:
            let deletePending = length == 0 ? true : try input.readUInt8() != 0
            if deletePending {
                if file.isDirectory,
                   let entries = try? FileManager.default.contentsOfDirectory(atPath: file.url.path), !entries.isEmpty {
                    return reply(RDPNTStatus.directoryNotEmpty)
                }
                guard access(file.url.deletingLastPathComponent().path, W_OK) == 0 else {
                    return reply(RDPNTStatus.accessDenied)
                }
            }
            file.deleteOnClose = deletePending
            files[request.fileID] = file
            return reply(RDPNTStatus.success)

        case InformationClass.rename:
            guard length >= 6 else { return reply(RDPNTStatus.invalidParameter) }
            let replaceIfExists = try input.readUInt8() != 0
            _ = try input.readUInt8()   // RootDirectory
            let nameLength = try input.readLittleEndianUInt32()
            let newPath = try Self.readPath(&input, length: nameLength)
            guard let target = resolve(newPath), target.path != root.path else { return reply(RDPNTStatus.accessDenied) }
            let sameItem = target.path.lowercased() == file.url.path.lowercased()   // nur Groß-/Kleinschreibung
            if !sameItem, FileManager.default.fileExists(atPath: target.path) {
                guard replaceIfExists else { return reply(RDPNTStatus.objectNameCollision) }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
                guard !isDirectory.boolValue else { return reply(RDPNTStatus.accessDenied) }
            }
            guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
                return reply(RDPNTStatus.objectPathNotFound)
            }
            try? file.handle?.close()
            file.handle = nil
            file.handleWritable = false
            guard Darwin.rename(file.url.path, target.path) == 0 else { return reply(Self.status(errno: errno)) }
            let oldPrefix = file.url.path
            file.url = target
            file.path = newPath
            files[request.fileID] = file
            // Offene Einträge darunter (Ordner umbenannt) mitziehen
            for (id, other) in files where other.url.path.hasPrefix(oldPrefix + "/") {
                files[id]?.url = URL(filePath: target.path + other.url.path.dropFirst(oldPrefix.count))
            }
            return reply(RDPNTStatus.success)

        default:
            return reply(RDPNTStatus.notSupported)
        }
    }

    static func unixTime(fileTime: UInt64) -> Darwin.timespec? {
        guard fileTime != 0, fileTime != UInt64.max else { return nil }
        let seconds = Int64(fileTime / 10_000_000) - 11_644_473_600
        return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int(fileTime % 10_000_000) * 100)
    }

    // MARK: Read / Write

    private func handle(for fileID: UInt32, writing: Bool) throws -> FileHandle? {
        guard var file = files[fileID], !file.isDirectory else { return nil }
        if let handle = file.handle, !writing || file.handleWritable { return handle }
        try? file.handle?.close()
        let handle = writing ? try FileHandle(forUpdating: file.url) : try FileHandle(forReadingFrom: file.url)
        file.handle = handle
        file.handleWritable = writing
        files[fileID] = file
        return handle
    }

    private func read(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let length = try body.readLittleEndianUInt32()
        let offset = try body.readLittleEndianUInt64()
        guard files[request.fileID] != nil else { return completion(request, status: RDPNTStatus.invalidHandle, uint32(0)) }
        do {
            guard let handle = try handle(for: request.fileID, writing: false) else {
                return completion(request, status: RDPNTStatus.fileIsADirectory, uint32(0))
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(min(length, 1 << 20))) ?? Data()
            return completion(request, status: RDPNTStatus.success, uint32(UInt32(data.count)) + data)
        } catch {
            return completion(request, status: Self.status(for: error), uint32(0))
        }
    }

    private func write(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let length = try body.readLittleEndianUInt32()
        let offset = try body.readLittleEndianUInt64()
        _ = try body.readData(count: 20)   // Padding
        let data = try body.readData(count: Int(length))
        guard files[request.fileID] != nil else {
            return completion(request, status: RDPNTStatus.invalidHandle, uint32(0) + Data([0]))
        }
        do {
            guard let handle = try handle(for: request.fileID, writing: true) else {
                return completion(request, status: RDPNTStatus.fileIsADirectory, uint32(0) + Data([0]))
            }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            return completion(request, status: RDPNTStatus.success, uint32(length) + Data([0]))
        } catch {
            return completion(request, status: Self.status(for: error), uint32(0) + Data([0]))
        }
    }

    // MARK: Abfragen

    private func queryInformation(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let infoClass = try body.readLittleEndianUInt32()
        guard let file = files[request.fileID] else {
            return completion(request, status: RDPNTStatus.invalidHandle, uint32(0))
        }
        guard let info = RDPDriveFileInfo.load(file.url, name: file.url.lastPathComponent) else {
            return completion(request, status: RDPNTStatus.objectNameNotFound, uint32(0))
        }
        var buffer = Data()
        switch infoClass {
        case InformationClass.basic:
            buffer.appendLittleEndianUInt64(info.creationTime)
            buffer.appendLittleEndianUInt64(info.accessTime)
            buffer.appendLittleEndianUInt64(info.writeTime)
            buffer.appendLittleEndianUInt64(info.changeTime)
            buffer.appendLittleEndianUInt32(info.attributes)
        case InformationClass.standard:
            buffer.appendLittleEndianUInt64(info.allocationSize)
            buffer.appendLittleEndianUInt64(info.size)
            buffer.appendLittleEndianUInt32(1)          // NumberOfLinks
            buffer.append(file.deleteOnClose ? 1 : 0)   // DeletePending
            buffer.append(info.isDirectory ? 1 : 0)
        case InformationClass.attributeTag:
            buffer.appendLittleEndianUInt32(info.attributes)
            buffer.appendLittleEndianUInt32(0)          // ReparseTag
        default:
            return completion(request, status: RDPNTStatus.notSupported, uint32(0))
        }
        return completion(request, status: RDPNTStatus.success, uint32(UInt32(buffer.count)) + buffer)
    }

    private func queryVolume(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let infoClass = try body.readLittleEndianUInt32()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        let total = (attributes?[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let unit: UInt64 = 4096
        var buffer = Data()
        switch infoClass {
        case InformationClass.fsVolume:
            let label = Self.utf16(name, terminated: false)
            buffer.appendLittleEndianUInt64(RDPDriveFileInfo.load(root, name: name)?.creationTime ?? 0)
            buffer.appendLittleEndianUInt32(Self.serialNumber(for: name))
            buffer.appendLittleEndianUInt32(UInt32(label.count))
            buffer.append(0)   // SupportsObjects
            buffer.append(label)
        case InformationClass.fsSize:
            buffer.appendLittleEndianUInt64(total / unit)
            buffer.appendLittleEndianUInt64(free / unit)
            buffer.appendLittleEndianUInt32(8)     // SectorsPerAllocationUnit
            buffer.appendLittleEndianUInt32(512)   // BytesPerSector
        case InformationClass.fsFullSize:
            buffer.appendLittleEndianUInt64(total / unit)
            buffer.appendLittleEndianUInt64(free / unit)
            buffer.appendLittleEndianUInt64(free / unit)
            buffer.appendLittleEndianUInt32(8)
            buffer.appendLittleEndianUInt32(512)
        case InformationClass.fsAttribute:
            let fileSystem = Self.utf16("FAT32", terminated: false)
            // FILE_CASE_SENSITIVE_SEARCH | FILE_CASE_PRESERVED_NAMES | FILE_UNICODE_ON_DISK
            buffer.appendLittleEndianUInt32(0x0000_0007)
            buffer.appendLittleEndianUInt32(255)   // MaximumComponentNameLength
            buffer.appendLittleEndianUInt32(UInt32(fileSystem.count))
            buffer.append(fileSystem)
        case InformationClass.fsDevice:
            buffer.appendLittleEndianUInt32(0x0000_0007)   // FILE_DEVICE_DISK
            buffer.appendLittleEndianUInt32(0x0000_0020)   // FILE_DEVICE_IS_MOUNTED
        default:
            return completion(request, status: RDPNTStatus.notSupported, uint32(0))
        }
        return completion(request, status: RDPNTStatus.success, uint32(UInt32(buffer.count)) + buffer)
    }

    /// Ein Eintrag je Anfrage (wie FreeRDP): `InitialQuery` liest den Ordner mit Muster, Folgeanfragen liefern den
    /// nächsten Eintrag, am Ende STATUS_NO_MORE_FILES.
    private func queryDirectory(_ request: RDPDeviceIORequest, body: inout ByteCursor) throws -> Data {
        let infoClass = try body.readLittleEndianUInt32()
        let initialQuery = try body.readUInt8() != 0
        let pathLength = try body.readLittleEndianUInt32()
        _ = try body.readData(count: 23)   // Padding
        let pattern = try Self.readPath(&body, length: pathLength)
        let noMore = completion(request, status: RDPNTStatus.noMoreFiles, uint32(0) + Data([0]))
        guard var file = files[request.fileID] else {
            return completion(request, status: RDPNTStatus.invalidHandle, uint32(0) + Data([0]))
        }
        if initialQuery || file.listing == nil {
            file.listing = listing(for: pattern, in: file)
            file.listingIndex = 0
        }
        guard let entries = file.listing, file.listingIndex < entries.count else {
            files[request.fileID] = file
            return noMore
        }
        let entry = entries[file.listingIndex]
        file.listingIndex += 1
        files[request.fileID] = file
        guard let buffer = Self.directoryEntry(entry, infoClass: infoClass) else {
            return completion(request, status: RDPNTStatus.notSupported, uint32(0) + Data([0]))
        }
        return completion(request, status: RDPNTStatus.success, uint32(UInt32(buffer.count)) + buffer)
    }

    /// Muster wie `\Ordner\*` oder `\Ordner\Datei.txt`; ohne Muster der Ordner der Datei-ID.
    private func listing(for pattern: String, in file: OpenFile) -> [RDPDriveFileInfo] {
        let separator = pattern.lastIndex(where: { $0 == "\\" || $0 == "/" })
        let folderPath = separator.map { String(pattern[..<$0]) } ?? file.path
        let mask = separator.map { String(pattern[pattern.index(after: $0)...]) } ?? (pattern.isEmpty ? "*" : pattern)
        guard let folder = resolve(folderPath),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { Self.matches($0.precomposedStringWithCanonicalMapping, mask: mask.isEmpty ? "*" : mask) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            // macOS liefert Namen teils zerlegt (NFD), Windows erwartet NFC
            .compactMap { RDPDriveFileInfo.load(folder.appending(path: $0), name: $0.precomposedStringWithCanonicalMapping) }
    }

    /// Windows-Platzhalter `*` und `?`, ohne Groß-/Kleinschreibung („*.*“ passt auf alles).
    static func matches(_ name: String, mask: String) -> Bool {
        if mask == "*" || mask == "*.*" { return true }
        return fnmatch(mask.lowercased(), name.lowercased(), 0) == 0
    }

    static func directoryEntry(_ info: RDPDriveFileInfo, infoClass: UInt32) -> Data? {
        let fileName = utf16(info.name, terminated: false)
        var data = Data()
        data.appendLittleEndianUInt32(0)   // NextEntryOffset
        data.appendLittleEndianUInt32(0)   // FileIndex
        switch infoClass {
        case InformationClass.names:
            data.appendLittleEndianUInt32(UInt32(fileName.count))
            data.append(fileName)
            return data
        case InformationClass.directory, InformationClass.fullDirectory, InformationClass.bothDirectory:
            data.appendLittleEndianUInt64(info.creationTime)
            data.appendLittleEndianUInt64(info.accessTime)
            data.appendLittleEndianUInt64(info.writeTime)
            data.appendLittleEndianUInt64(info.changeTime)
            data.appendLittleEndianUInt64(info.size)
            data.appendLittleEndianUInt64(info.allocationSize)
            data.appendLittleEndianUInt32(info.attributes)
            data.appendLittleEndianUInt32(UInt32(fileName.count))
            if infoClass != InformationClass.directory { data.appendLittleEndianUInt32(0) }   // EaSize
            if infoClass == InformationClass.bothDirectory {
                // ShortNameLength + ShortName; das Reserved-Byte aus MS-FSCC sendet Windows über rdpdr nicht
                // (wie FreeRDP) – sonst verschiebt sich der Name und der Explorer bricht ab.
                data.append(0)
                data.append(Data(count: 24))
            }
            data.append(fileName)
            return data
        default:
            return nil
        }
    }

    // MARK: Hilfen

    private func completion(_ request: RDPDeviceIORequest, status: UInt32, _ output: Data) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(request.deviceID)
        payload.appendLittleEndianUInt32(request.completionID)
        payload.appendLittleEndianUInt32(status)
        payload.append(output)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.deviceIOCompletion),
            payload: payload
        ).encoded()
    }

    private func uint32(_ value: UInt32) -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(value)
        return data
    }

    static func utf16(_ text: String, terminated: Bool = true) -> Data {
        var data = Data()
        for unit in text.utf16 { data.appendLittleEndianUInt16(unit) }
        if terminated { data.appendLittleEndianUInt16(0) }
        return data
    }

    private static func serialNumber(for name: String) -> UInt32 {
        name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    static func status(for error: any Error) -> UInt32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return status(errno: Int32(nsError.code)) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return status(errno: Int32(underlying.code))
        }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return RDPNTStatus.objectNameNotFound
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return RDPNTStatus.accessDenied
        case NSFileWriteOutOfSpaceError: return RDPNTStatus.diskFull
        case NSFileWriteFileExistsError: return RDPNTStatus.objectNameCollision
        default: return RDPNTStatus.unsuccessful
        }
    }

    static func status(errno code: Int32) -> UInt32 {
        switch code {
        case ENOENT: RDPNTStatus.objectNameNotFound
        case EACCES, EPERM, EROFS: RDPNTStatus.accessDenied
        case EEXIST: RDPNTStatus.objectNameCollision
        case ENOSPC, EDQUOT: RDPNTStatus.diskFull
        case ENOTDIR: RDPNTStatus.notADirectory
        case EISDIR: RDPNTStatus.fileIsADirectory
        case ENOTEMPTY: RDPNTStatus.directoryNotEmpty
        default: RDPNTStatus.unsuccessful
        }
    }
}
