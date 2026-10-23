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
