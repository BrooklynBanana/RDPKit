import Foundation
@testable import RDPKit
import Testing

// Fork-Tests: Windows Server 2008 R2 (CredSSP-Retry mit v3, Bitmap-Modus ohne RDPGFX).

@Suite(.serialized)
struct LegacyServerForkTests {
    private let credentials = RDPCredentials(username: "rdp-user", password: "secret")

    private func configuration(port: UInt16) -> RDPConnectionConfiguration {
        RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: port,
            credentials: credentials,
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    }

    @Test func credSSPRetriesWithLegacyV3WhenV5ServerClosesAfterModernBinding() throws {
        let server = try MockKRDPServer.start(
            securityProtocol: .credSSP(credentials: credentials),
            credSSPBehavior: .legacyBindingOnly
        )
        defer { server.stop() }

        let report = RDPPreflightClient().run(configuration: configuration(port: server.port))

        let transcript = server.transcript.snapshot
        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(server.connectionCount == 2)
        #expect(transcript.credSSPMessages == [
            "ntlm-negotiate", "ntlm-authenticate",
            "ntlm-negotiate", "ntlm-authenticate", "credentials",
        ])
        #expect(transcript.credSSPGates == [
            "raw-ntlm-negotiate-token",
            "initial-client-nonce",
            "authenticate-client-nonce",
            "raw-ntlm-authenticate-token",
            "ntlm-channel-bindings",
            "rejected-modern-binding",
            "legacy-v3-negotiate-without-nonce",
            "raw-ntlm-authenticate-token",
            "ntlm-channel-bindings",
            "legacy-pubkeyauth",
            "credentials-client-nonce",
        ])
    }

    @Test func credSSPDoesNotRetryWhenV6ServerClosesAfterAuthenticate() throws {
        let server = try MockKRDPServer.start(
            securityProtocol: .credSSP(credentials: credentials),
            credSSPBehavior: .closeAfterAuthenticate
        )
        defer { server.stop() }

        let report = RDPPreflightClient().run(configuration: configuration(port: server.port))

        let transcript = server.transcript.snapshot
        #expect(report.status == "failure")
        #expect(report.stage == "tls-upgrade")
        #expect(server.connectionCount == 1)
        #expect(transcript.credSSPMessages == ["ntlm-negotiate", "ntlm-authenticate"])
        #expect(transcript.credSSPGates.last == "closed-after-authenticate")
        #expect(transcript.credSSPGates.contains("legacy-v3-negotiate-without-nonce") == false)
    }

    @Test func effectiveCredSSPVersionCapsAtThreeInLegacyMode() throws {
        #expect(try effectiveCredSSPVersion(6, legacyMode: true) == 3)
        #expect(try effectiveCredSSPVersion(5, legacyMode: true) == 3)
        #expect(try effectiveCredSSPVersion(3, legacyMode: true) == 3)
        #expect(try effectiveCredSSPVersion(2, legacyMode: true) == 2)
        #expect(try effectiveCredSSPVersion(7) == 6)
        #expect(try effectiveCredSSPVersion(6) == 6)
        #expect(try effectiveCredSSPVersion(5) == 5)
        #expect(try effectiveCredSSPVersion(3) == 3)
        #expect(throws: RDPCredSSPError.self) {
            _ = try effectiveCredSSPVersion(1, legacyMode: true)
        }
    }

    @Test func surfaceCommandsBeforeRDPGFXSwitchToLegacyBitmapMode() throws {
        let server = try MockKRDPServer.start(graphicsBehavior: .sendLegacySurfaceCommandsWithoutRDPGFX)
        defer { server.stop() }

        let frames = FrameCollector()
        let report = RDPPreflightClient().run(
            configuration: configuration(port: server.port),
            onGraphicsFrame: { frames.append($0) }
        )

        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(report.rdpGraphicsSelectedCapabilityVersion == nil)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "surface-bgra")
        #expect(report.rdpGraphicsFirstFrame?.frameID == 7)
        #expect(frames.count == 1)
        #expect(frames.first?.codecName == "surface-bgra")
    }

    @Test func bitmapUpdateBeforeRDPGFXSwitchesToLegacyBitmapMode() throws {
        let server = try MockKRDPServer.start(graphicsBehavior: .sendLegacyBitmapUpdateWithoutRDPGFX)
        defer { server.stop() }

        let frames = FrameCollector()
        let report = RDPPreflightClient().run(
            configuration: configuration(port: server.port),
            onGraphicsFrame: { frames.append($0) }
        )

        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(report.rdpGraphicsSelectedCapabilityVersion == nil)
        #expect(report.rdpGraphicsFirstFrame != nil)
        #expect(frames.count == 1)
    }

    @Test func fastPathPointerBeforeRDPGFXDoesNotSwitchToLegacyBitmapMode() throws {
        let server = try MockKRDPServer.start(graphicsBehavior: .sendFastPathPointerBeforeFirstFrame)
        defer { server.stop() }

        let report = RDPPreflightClient().run(configuration: configuration(port: server.port))

        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(report.rdpGraphicsSelectedCapabilityVersion != nil)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RDPGraphicsFrameSnapshot] = []

    func append(_ frame: RDPGraphicsFrameSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    var first: RDPGraphicsFrameSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first
    }
}
