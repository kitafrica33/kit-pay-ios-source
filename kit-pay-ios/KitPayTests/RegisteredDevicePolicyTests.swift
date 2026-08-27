import Foundation
import XCTest
@testable import KitPay

final class RegisteredDevicePolicyTests: XCTestCase {
    func testDeviceListDecodesCurrentAndLegacyDeviceProjections() throws {
        let response = try JSONDecoder().decode(DeviceListDTO.self, from: Data(#"""
        {
          "items": [
            {
              "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "name": "Arnold's iPhone",
              "platform": "ios",
              "model": "iPhone 15 Pro",
              "is_current": true,
              "is_trusted": true,
              "trust_expires_at": "2030-08-20T10:40:46.123Z",
              "last_seen_at": "2026-08-20T10:40:46Z",
              "created_at": "2026-08-18T10:40:31Z"
            },
            {
              "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              "name": "Web browser",
              "platform": "web"
            }
          ]
        }
        """#.utf8))

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].name, "Arnold's iPhone")
        XCTAssertEqual(response.items[0].model, "iPhone 15 Pro")
        XCTAssertEqual(response.items[0].isCurrent, true)
        XCTAssertEqual(response.items[0].isTrusted, true)
        XCTAssertEqual(response.items[0].trustExpiresAt, "2030-08-20T10:40:46.123Z")
        XCTAssertEqual(response.items[0].lastSeenAt, "2026-08-20T10:40:46Z")
        XCTAssertEqual(response.items[0].createdAt, "2026-08-18T10:40:31Z")
        XCTAssertNil(response.items[1].model)
        XCTAssertNil(response.items[1].isCurrent)
        XCTAssertNil(response.items[1].isTrusted)
        XCTAssertNil(response.items[1].trustExpiresAt)
    }

    func testDeviceListRequiresItemsEnvelope() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DeviceListDTO.self,
                from: Data(#"{"devices":[]}"#.utf8)
            )
        )
    }

    func testValidationCanonicalizesFieldsAndOrdersCurrentDeviceFirst() throws {
        let currentID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let recentID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let olderID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let devices = [
            device(
                id: olderID,
                name: "Older web session",
                platform: "web",
                isCurrent: false,
                lastSeenAt: "2026-08-18T08:00:00Z"
            ),
            device(
                id: currentID,
                name: "  Arnold's iPhone  ",
                platform: "iOS",
                model: "  iPhone 15 Pro  ",
                isCurrent: true,
                lastSeenAt: "2026-08-17T08:00:00Z"
            ),
            device(
                id: recentID,
                name: "Recent Android",
                platform: "android",
                isCurrent: false,
                lastSeenAt: "2026-08-20T08:00:00.123Z"
            ),
        ]

        let validated = try XCTUnwrap(RegisteredDevicePolicy.validated(devices))

        XCTAssertEqual(validated.map(\.id), [currentID.lowercased(), recentID, olderID])
        XCTAssertEqual(validated[0].name, "Arnold's iPhone")
        XCTAssertEqual(validated[0].platform, "ios")
        XCTAssertEqual(validated[0].model, "iPhone 15 Pro")
    }

    func testValidationRejectsEmptyDuplicateAndAmbiguousCurrentDirectories() {
        let current = device(id: currentID, isCurrent: true)
        let remote = device(id: remoteID, isCurrent: false)

        XCTAssertNil(RegisteredDevicePolicy.validated([]))
        XCTAssertNil(RegisteredDevicePolicy.validated([remote]))
        XCTAssertNil(RegisteredDevicePolicy.validated([
            current,
            device(id: remoteID, isCurrent: true),
        ]))
        XCTAssertNil(RegisteredDevicePolicy.validated([
            current,
            device(id: currentID.uppercased(), isCurrent: false),
        ]))
    }

    func testValidationRejectsMalformedIdentityMetadataAndTimestamps() {
        let malformedDevices = [
            device(id: "not-a-device-id", isCurrent: true),
            device(id: " \(currentID)", isCurrent: true),
            device(id: currentID, name: "   ", isCurrent: true),
            device(id: currentID, name: "Unsafe\u{0007}name", isCurrent: true),
            device(id: currentID, platform: "watchos", isCurrent: true),
            device(id: currentID, platform: " ios ", isCurrent: true),
            device(id: currentID, model: String(repeating: "x", count: 121), isCurrent: true),
            device(id: currentID, isCurrent: true, lastSeenAt: "yesterday"),
            device(id: currentID, isCurrent: true, trustExpiresAt: "2030-08-20"),
        ]

        for malformed in malformedDevices {
            XCTAssertNil(
                RegisteredDevicePolicy.validated([malformed]),
                "Expected malformed device to be rejected: \(malformed)"
            )
        }
    }

    func testValidationAcceptsBackendValidUnicodeDeviceMetadata() throws {
        let emojiName = String(repeating: "📱", count: 60)
        let emojiModel = String(repeating: "✨", count: 60)
        let validated = try XCTUnwrap(RegisteredDevicePolicy.validated([
            device(
                id: currentID,
                name: emojiName,
                model: emojiModel,
                isCurrent: true
            ),
        ]))

        XCTAssertEqual(validated.first?.name, emojiName)
        XCTAssertEqual(validated.first?.model, emojiModel)
    }

    func testValidationBoundsDeviceCount() {
        var devices = [device(id: currentID, isCurrent: true)]
        devices.append(contentsOf: (0..<1_000).map { index in
            device(id: UUID().uuidString, name: "Device \(index)", isCurrent: false)
        })

        XCTAssertNil(RegisteredDevicePolicy.validated(devices))
    }

    func testTrustRequiresServerFlagAndFutureExpiry() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")
        )
        let devices = [
            device(
                id: currentID,
                isCurrent: true,
                isTrusted: true,
                trustExpiresAt: "2030-08-20T12:00:00Z"
            ),
            device(
                id: remoteID,
                isCurrent: false,
                isTrusted: true,
                trustExpiresAt: "2020-08-20T12:00:00Z"
            ),
            device(
                id: thirdID,
                isCurrent: false,
                isTrusted: true
            ),
            device(
                id: fourthID,
                isCurrent: false,
                isTrusted: false,
                trustExpiresAt: "2030-08-20T12:00:00Z"
            ),
        ]

        let validated = try XCTUnwrap(RegisteredDevicePolicy.validated(devices, now: now))
        let trustByID = Dictionary(
            uniqueKeysWithValues: validated.map { ($0.id, $0.isTrusted == true) }
        )

        XCTAssertEqual(trustByID[currentID], true)
        XCTAssertEqual(trustByID[remoteID], false)
        XCTAssertEqual(trustByID[thirdID], false)
        XCTAssertEqual(trustByID[fourthID], false)
        let current = try XCTUnwrap(validated.first(where: { $0.id == currentID }))
        XCTAssertTrue(RegisteredDevicePolicy.hasActiveTrust(current, now: now))
        let afterExpiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2031-08-20T12:00:00Z")
        )
        XCTAssertFalse(RegisteredDevicePolicy.hasActiveTrust(current, now: afterExpiry))
    }

    func testRevocationRejectsCurrentAndMalformedDevices() {
        XCTAssertFalse(RegisteredDevicePolicy.canRevoke(device(id: currentID, isCurrent: true)))
        XCTAssertFalse(RegisteredDevicePolicy.canRevoke(
            device(id: "not-a-device-id", isCurrent: false)
        ))
        XCTAssertFalse(RegisteredDevicePolicy.canRevoke(
            device(id: " \(remoteID)", isCurrent: false)
        ))
        XCTAssertTrue(RegisteredDevicePolicy.canRevoke(device(id: remoteID, isCurrent: false)))
    }

    func testPersistedProjectionRevisionAdvancesWithEveryAuthoritativeReplacement() {
        var state = PersistedState.empty
        XCTAssertEqual(state.currentRegisteredDeviceProjectionRevision, 0)

        state.replaceRegisteredDeviceProjection([device(id: currentID, isCurrent: true)])
        XCTAssertEqual(state.currentRegisteredDeviceProjectionRevision, 1)
        XCTAssertEqual(state.registeredDevices?.map(\.id), [currentID])

        state.replaceRegisteredDeviceProjection([
            device(id: currentID, isCurrent: true),
            device(id: remoteID, isCurrent: false),
        ])
        XCTAssertEqual(state.currentRegisteredDeviceProjectionRevision, 2)
        XCTAssertEqual(state.registeredDevices?.map(\.id), [currentID, remoteID])
    }

    private let currentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let remoteID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let thirdID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let fourthID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    private func device(
        id: String,
        name: String = "Arnold's iPhone",
        platform: String = "ios",
        model: String? = "iPhone 15 Pro",
        isCurrent: Bool?,
        isTrusted: Bool? = nil,
        trustExpiresAt: String? = nil,
        lastSeenAt: String? = nil,
        createdAt: String? = nil
    ) -> DeviceDTO {
        DeviceDTO(
            id: id,
            name: name,
            platform: platform,
            model: model,
            isCurrent: isCurrent,
            isTrusted: isTrusted,
            trustExpiresAt: trustExpiresAt,
            lastSeenAt: lastSeenAt,
            createdAt: createdAt
        )
    }
}
