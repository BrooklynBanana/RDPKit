import Foundation
@testable import RDPKit
import Testing

// Connection Manager: Laufwerksumleitung – IRPs gegen einen temporären Ordner.

private struct DriveFixture {
    let root: URL
    let device: RDPDriveDevice
    var completion: UInt32 = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "rdpkit-drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        device = RDPDriveDevice(deviceID: 1, name: "Mac", root: root)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    struct Reply {
        var status: UInt32
        var output: Data
        var uint32: UInt32 { output.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    }

    mutating func send(major: UInt32, minor: UInt32 = 0, fileID: UInt32 = 0, body: Data) -> Reply? {
        completion += 1
        let request = RDPDeviceIORequest(deviceID: 1, fileID: fileID, completionID: completion,
                                         majorFunction: major, minorFunction: minor, body: body)
        guard let data = device.handle(request) else { return nil }
        var cursor = ByteCursor(data)
        _ = try? cursor.readLittleEndianUInt32()   // Kopf
        _ = try? cursor.readLittleEndianUInt32()   // DeviceId
        #expect((try? cursor.readLittleEndianUInt32()) == completion)
        let status = (try? cursor.readLittleEndianUInt32()) ?? 0xFFFF_FFFF
        return Reply(status: status, output: cursor.readRemainingData())
    }

    mutating func create(_ path: String, disposition: UInt32 = 1, options: UInt32 = 0,
                         access: UInt32 = 0x8000_0000) -> (status: UInt32, fileID: UInt32, information: UInt8) {
        var body = Data()
        body.appendLittleEndianUInt32(access)
        body.appendLittleEndianUInt64(0)
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt32(7)
        body.appendLittleEndianUInt32(disposition)
        body.appendLittleEndianUInt32(options)
        let path = RDPDriveDevice.utf16(path)
        body.appendLittleEndianUInt32(UInt32(path.count))
        body.append(path)
        let reply = send(major: RDPIRPMajor.create, body: body)!
        return (reply.status, reply.uint32, reply.output.count > 4 ? reply.output[reply.output.startIndex + 4] : 0xFF)
    }

    mutating func read(_ fileID: UInt32, length: UInt32, offset: UInt64 = 0) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(length)
        body.appendLittleEndianUInt64(offset)
        body.append(Data(count: 20))
        return send(major: RDPIRPMajor.read, fileID: fileID, body: body)!
    }

    mutating func write(_ fileID: UInt32, _ data: Data, offset: UInt64 = 0) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(UInt32(data.count))
        body.appendLittleEndianUInt64(offset)
        body.append(Data(count: 20))
        body.append(data)
        return send(major: RDPIRPMajor.write, fileID: fileID, body: body)!
    }

    mutating func close(_ fileID: UInt32) {
        #expect(send(major: RDPIRPMajor.close, fileID: fileID, body: Data(count: 32))?.status == 0)
    }

    mutating func query(_ major: UInt32, fileID: UInt32, infoClass: UInt32) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(infoClass)
        body.appendLittleEndianUInt32(0)
        body.append(Data(count: 24))
        return send(major: major, fileID: fileID, body: body)!
    }

    /// Alle Namen eines Ordners (FileBothDirectoryInformation, ein Eintrag je Anfrage).
    mutating func list(_ fileID: UInt32, pattern: String) -> [String] {
        var names: [String] = []
        var initial = true
        while true {
            var body = Data()
            body.appendLittleEndianUInt32(3)
            body.append(initial ? 1 : 0)
            let path = RDPDriveDevice.utf16(pattern)
            body.appendLittleEndianUInt32(initial ? UInt32(path.count) : 0)
            body.append(Data(count: 23))
            if initial { body.append(path) }
            initial = false
            let reply = send(major: RDPIRPMajor.directoryControl, minor: RDPIRPMinor.queryDirectory,
                             fileID: fileID, body: body)!
            if reply.status == RDPNTStatus.noMoreFiles { return names }
            #expect(reply.status == 0)
            let entry = reply.output.dropFirst(4)
            // FileNameLength bei Offset 60, Name ab 93 (FILE_BOTH_DIR_INFORMATION ohne Reserved-Byte)
            let nameLength = Int(entry[entry.startIndex + 60]) | Int(entry[entry.startIndex + 61]) << 8
            let nameData = entry.dropFirst(93).prefix(nameLength)
            let units = stride(from: nameData.startIndex, to: nameData.endIndex, by: 2).map {
                UInt16(nameData[$0]) | UInt16(nameData[$0 + 1]) << 8
            }
            names.append(String(decoding: units, as: UTF16.self))
            if names.count > 100 { return names }
        }
    }
}

@Test func drivePathsStayInsideTheSharedFolder() throws {
    let fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    #expect(fixture.device.resolve("\\") == fixture.root.standardizedFileURL)
    #expect(fixture.device.resolve("\\a\\b.txt")?.path == fixture.root.standardizedFileURL.path + "/a/b.txt")
    #expect(fixture.device.resolve("\\..\\etc\\passwd") == nil)
    #expect(fixture.device.resolve("\\a\\..\\..\\x") == nil)
}

@Test func driveReadsExistingFiles() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    try Data("Hallo Windows".utf8).write(to: fixture.root.appending(path: "gruß.txt"))
    let opened = fixture.create("\\gruß.txt")
    #expect(opened.status == 0 && opened.fileID != 0 && opened.information == 1)
    let reply = fixture.read(opened.fileID, length: 5, offset: 6)
    #expect(reply.status == 0 && reply.uint32 == 5 && reply.output.dropFirst(4) == Data("Windo".utf8))
    let standard = fixture.query(RDPIRPMajor.queryInformation, fileID: opened.fileID, infoClass: 5)
    #expect(standard.status == 0 && standard.uint32 == 22)
    #expect(standard.output[standard.output.startIndex + 12] == 13)   // EndOfFile
    fixture.close(opened.fileID)
    #expect(fixture.read(opened.fileID, length: 5).status == RDPNTStatus.invalidHandle)
}

@Test func driveCreatesWritesAndOverwritesFiles() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let created = fixture.create("\\neu.bin", disposition: 2, access: 0x4000_0000)
    #expect(created.status == 0 && created.information == 2)
    let data = Data((0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    #expect(fixture.write(created.fileID, data).uint32 == 70_000)
    #expect(fixture.write(created.fileID, Data("XY".utf8), offset: 10).status == 0)
    fixture.close(created.fileID)
    var expected = data
    expected.replaceSubrange(10 ..< 12, with: Data("XY".utf8))
    #expect(try Data(contentsOf: fixture.root.appending(path: "neu.bin")) == expected)

    #expect(fixture.create("\\neu.bin", disposition: 2).status == RDPNTStatus.objectNameCollision)
    let overwritten = fixture.create("\\neu.bin", disposition: 5, access: 0x4000_0000)
    #expect(overwritten.status == 0 && overwritten.information == 3)
    fixture.close(overwritten.fileID)
    #expect(try Data(contentsOf: fixture.root.appending(path: "neu.bin")).isEmpty)
}

@Test func driveReportsMissingPathsAndDirectories() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    #expect(fixture.create("\\fehlt.txt").status == RDPNTStatus.objectNameNotFound)
    #expect(fixture.create("\\fehlt\\x.txt").status == RDPNTStatus.objectPathNotFound)
    #expect(fixture.create("\\..\\x").status == RDPNTStatus.accessDenied)

    let folder = fixture.create("\\Ordner", disposition: 2, options: 0x1)
    #expect(folder.status == 0 && folder.information == 2)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Ordner").path, isDirectory: &isDirectory)
        && isDirectory.boolValue)
    #expect(fixture.create("\\Ordner", options: 0x40).status == RDPNTStatus.fileIsADirectory)
    try Data().write(to: fixture.root.appending(path: "datei"))
    #expect(fixture.create("\\datei", options: 0x1).status == RDPNTStatus.notADirectory)
}

@Test func driveListsDirectoriesOneEntryAtATime() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    for name in ["b.txt", "A.txt", "Übersicht.pdf"] { try Data().write(to: fixture.root.appending(path: name)) }
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "Ordner"), withIntermediateDirectories: false)
    let root = fixture.create("\\", options: 0x1)
    #expect(root.status == 0)
    #expect(fixture.list(root.fileID, pattern: "\\*") == ["A.txt", "b.txt", "Ordner", "Übersicht.pdf"])
    #expect(fixture.list(root.fileID, pattern: "\\*.TXT") == ["A.txt", "b.txt"])
    #expect(fixture.list(root.fileID, pattern: "\\gibts-nicht") == [])
}

@Test func driveAnswersVolumeQueries() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let root = fixture.create("\\", options: 0x1)
    let attributes = fixture.query(RDPIRPMajor.queryVolumeInformation, fileID: root.fileID, infoClass: 5)
    #expect(attributes.status == 0 && attributes.output.suffix(10) == RDPDriveDevice.utf16("FAT32", terminated: false))
    let size = fixture.query(RDPIRPMajor.queryVolumeInformation, fileID: root.fileID, infoClass: 7)
    #expect(size.status == 0 && size.uint32 == 32)
    let volume = fixture.query(RDPIRPMajor.queryVolumeInformation, fileID: root.fileID, infoClass: 1)
    #expect(volume.status == 0 && volume.output.suffix(6) == RDPDriveDevice.utf16("Mac", terminated: false))
    #expect(fixture.query(RDPIRPMajor.queryVolumeInformation, fileID: root.fileID, infoClass: 99).status
        == RDPNTStatus.notSupported)
}

@Test func driveDeclinesChangeNotifications() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let root = fixture.create("\\", options: 0x1)
    #expect(fixture.send(major: RDPIRPMajor.directoryControl, minor: RDPIRPMinor.notifyChangeDirectory,
                         fileID: root.fileID, body: Data(count: 32))?.status == RDPNTStatus.notSupported)
}

@Test func driveWildcardsMatchLikeWindows() {
    #expect(RDPDriveDevice.matches("Bericht.PDF", mask: "*.pdf"))
    #expect(RDPDriveDevice.matches("ohne-endung", mask: "*.*"))
    #expect(RDPDriveDevice.matches("a1.txt", mask: "a?.txt"))
    #expect(!RDPDriveDevice.matches("b.txt", mask: "a*"))
}

@Test func deviceRedirectionReassemblesLargeWriteRequests() throws {
    let payload = Data((0 ..< 5_000).map { UInt8(truncatingIfNeeded: $0) })
    var reassembler = RDPStaticVirtualChannelReassembler()
    var result: RDPStaticVirtualChannelPDU?
    for chunk in RDPStaticVirtualChannelPDU.chunks(for: payload) {
        result = try reassembler.append(chunk)
    }
    #expect(result?.payload == payload)
}

@Test func driveWritesAfterReadingTheSameHandle() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    try Data("alt".utf8).write(to: fixture.root.appending(path: "notiz.txt"))
    // wie der Windows-Editor: einmal öffnen (Lesen und Schreiben), erst lesen, dann schreiben
    let opened = fixture.create("\\notiz.txt", disposition: 3, access: 0x0012_019F)
    #expect(fixture.read(opened.fileID, length: 4096).output.dropFirst(4) == Data("alt".utf8))
    #expect(fixture.write(opened.fileID, Data("neu!".utf8)).status == 0)
    fixture.close(opened.fileID)
    #expect(try Data(contentsOf: fixture.root.appending(path: "notiz.txt")) == Data("neu!".utf8))
}

// MARK: Set Information (7.5)

extension DriveFixture {
    mutating func setInformation(_ fileID: UInt32, infoClass: UInt32, _ data: Data) -> UInt32 {
        var body = Data()
        body.appendLittleEndianUInt32(infoClass)
        body.appendLittleEndianUInt32(UInt32(data.count))
        body.append(Data(count: 24))
        body.append(data)
        let reply = send(major: RDPIRPMajor.setInformation, fileID: fileID, body: body)!
        #expect(reply.uint32 == UInt32(data.count))
        return reply.status
    }

    mutating func rename(_ fileID: UInt32, to path: String, replace: Bool = false) -> UInt32 {
        let name = RDPDriveDevice.utf16(path, terminated: false)
        var data = Data([replace ? 1 : 0, 0])
        data.appendLittleEndianUInt32(UInt32(name.count))
        data.append(name)
        return setInformation(fileID, infoClass: 10, data)
    }
}

@Test func driveRenamesFilesAndFolders() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    try Data("a".utf8).write(to: fixture.root.appending(path: "alt.txt"))
    try Data("b".utf8).write(to: fixture.root.appending(path: "da.txt"))
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "Ordner"), withIntermediateDirectories: false)

    let file = fixture.create("\\alt.txt", access: 0x0001_0000)
    #expect(fixture.rename(file.fileID, to: "\\da.txt") == RDPNTStatus.objectNameCollision)
    #expect(fixture.rename(file.fileID, to: "\\..\\raus.txt") == RDPNTStatus.accessDenied)
    #expect(fixture.rename(file.fileID, to: "\\Ordner\\Grüße.txt") == 0)
    #expect(fixture.rename(file.fileID, to: "\\Ordner\\grüße.txt") == 0)   // nur Groß-/Kleinschreibung
    fixture.close(file.fileID)
    #expect(try Data(contentsOf: fixture.root.appending(path: "Ordner/grüße.txt")) == Data("a".utf8))

    let other = fixture.create("\\da.txt", access: 0x0001_0000)
    #expect(fixture.rename(other.fileID, to: "\\Ordner\\grüße.txt", replace: true) == 0)
    fixture.close(other.fileID)
    #expect(try Data(contentsOf: fixture.root.appending(path: "Ordner/grüße.txt")) == Data("b".utf8))

    let folder = fixture.create("\\Ordner", options: 0x1, access: 0x0001_0000)
    #expect(fixture.rename(folder.fileID, to: "\\Neu") == 0)
    fixture.close(folder.fileID)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Neu/grüße.txt").path))
}

@Test func driveDeletesOnCloseButNeverNonEmptyFolders() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    try Data("x".utf8).write(to: fixture.root.appending(path: "weg.txt"))
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "voll"), withIntermediateDirectories: false)
    try Data().write(to: fixture.root.appending(path: "voll/inhalt"))
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "leer"), withIntermediateDirectories: false)

    let file = fixture.create("\\weg.txt", access: 0x0001_0000)
    #expect(fixture.setInformation(file.fileID, infoClass: 13, Data([1])) == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "weg.txt").path))   // erst beim Schließen
    fixture.close(file.fileID)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "weg.txt").path))

    let full = fixture.create("\\voll", options: 0x1, access: 0x0001_0000)
    #expect(fixture.setInformation(full.fileID, infoClass: 13, Data([1])) == RDPNTStatus.directoryNotEmpty)
    fixture.close(full.fileID)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "voll/inhalt").path))
    // auch über FILE_DELETE_ON_CLOSE beim Öffnen: nicht leere Ordner bleiben stehen
    let fullAgain = fixture.create("\\voll", options: 0x1 | 0x1000, access: 0x0001_0000)
    fixture.close(fullAgain.fileID)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "voll/inhalt").path))

    let empty = fixture.create("\\leer", options: 0x1, access: 0x0001_0000)
    #expect(fixture.setInformation(empty.fileID, infoClass: 13, Data([1])) == 0)
    fixture.close(empty.fileID)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "leer").path))
}

@Test func driveSetsEndOfFileAndAllocation() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let url = fixture.root.appending(path: "groesse.bin")
    let file = fixture.create("\\groesse.bin", disposition: 2, access: 0x4000_0000)
    var size = Data()
    size.appendLittleEndianUInt64(1_000_000)
    #expect(fixture.setInformation(file.fileID, infoClass: 20, size) == 0)   // EndOfFile: vergrößern
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) == 1_000_000)
    var bigger = Data()
    bigger.appendLittleEndianUInt64(2_000_000)
    #expect(fixture.setInformation(file.fileID, infoClass: 19, bigger) == 0)  // Allocation größer: unverändert
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) == 1_000_000)
    #expect(fixture.write(file.fileID, Data("Ende".utf8), offset: 999_996).status == 0)
    var smaller = Data()
    smaller.appendLittleEndianUInt64(10)
    #expect(fixture.setInformation(file.fileID, infoClass: 19, smaller) == 0)  // Allocation kleiner: kürzt
    fixture.close(file.fileID)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) == 10)
}

@Test func driveSetsModificationTime() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let url = fixture.root.appending(path: "zeit.txt")
    try Data().write(to: url)
    let file = fixture.create("\\zeit.txt", access: 0x0000_0100)
    // 1.1.2020 00:00 UTC als FILETIME
    let fileTime: UInt64 = (1_577_836_800 + 11_644_473_600) * 10_000_000
    var data = Data()
    data.appendLittleEndianUInt64(0)
    data.appendLittleEndianUInt64(0)
    data.appendLittleEndianUInt64(fileTime)
    data.appendLittleEndianUInt64(0)
    data.appendLittleEndianUInt32(0x20)
    #expect(fixture.setInformation(file.fileID, infoClass: 4, data) == 0)
    fixture.close(file.fileID)
    let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    #expect(modified == Date(timeIntervalSince1970: 1_577_836_800))
}

@Test func driveLinksDoNotLeaveTheSharedFolder() throws {
    var fixture = try DriveFixture()
    defer { fixture.cleanUp() }
    let outside = FileManager.default.temporaryDirectory.appending(path: "rdpkit-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("geheim".utf8).write(to: outside.appending(path: "secret.txt"))
    let manager = FileManager.default
    try manager.createSymbolicLink(at: fixture.root.appending(path: "raus"), withDestinationURL: outside)
    try manager.createSymbolicLink(at: fixture.root.appending(path: "datei-raus.txt"),
                                   withDestinationURL: outside.appending(path: "secret.txt"))
    try manager.createSymbolicLink(at: fixture.root.appending(path: "haengt.txt"),
                                   withDestinationURL: outside.appending(path: "neu.txt"))
    try manager.createDirectory(at: fixture.root.appending(path: "innen"), withIntermediateDirectories: true)
    try Data("ok".utf8).write(to: fixture.root.appending(path: "innen/a.txt"))
    try manager.createSymbolicLink(at: fixture.root.appending(path: "drinnen"),
                                   withDestinationURL: fixture.root.appending(path: "innen"))

    #expect(fixture.create("\\raus\\secret.txt").status == RDPNTStatus.accessDenied)
    #expect(fixture.create("\\raus\\neu.txt", disposition: 3).status == RDPNTStatus.accessDenied)   // openIf
    #expect(fixture.create("\\datei-raus.txt").status == RDPNTStatus.accessDenied)
    #expect(fixture.create("\\haengt.txt", disposition: 3).status == RDPNTStatus.accessDenied)
    #expect(!manager.fileExists(atPath: outside.appending(path: "neu.txt").path))
    // Links innerhalb des Ordners und neue Dateien bleiben möglich
    let inside = fixture.create("\\drinnen\\a.txt")
    #expect(inside.status == 0)
    #expect(fixture.read(inside.fileID, length: 2).output.dropFirst(4) == Data("ok".utf8))
    #expect(fixture.create("\\innen\\neu\\x.txt", disposition: 3).status == RDPNTStatus.objectPathNotFound)
    #expect(fixture.create("\\neu.txt", disposition: 2).status == 0)
}
