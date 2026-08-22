import XCTest
@testable import KitPay

final class SecureMessagingCryptoTests: XCTestCase {
    func testPQXDHAndDoubleRatchetRoundTripPersistAcrossIndependentStores() async throws {
        let engine = SecureMessagingCryptoEngine()
        let aliceAddress = address(
            user: "10000000-0000-0000-0000-000000000001",
            device: "20000000-0000-0000-0000-000000000001"
        )
        let bobAddress = address(
            user: "10000000-0000-0000-0000-000000000002",
            device: "20000000-0000-0000-0000-000000000002"
        )

        let aliceProvisioned = try await engine.provision(from: .empty, preKeyCount: 2)
        let bobProvisioned = try await engine.provision(from: .empty, preKeyCount: 2)
        XCTAssertEqual(aliceProvisioned.state.pendingPublication, aliceProvisioned.bundle)
        XCTAssertEqual(bobProvisioned.state.pendingPublication, bobProvisioned.bundle)
        var aliceState = try await bind(
            aliceProvisioned,
            address: aliceAddress,
            engine: engine
        )
        var bobState = try await bind(
            bobProvisioned,
            address: bobAddress,
            engine: engine
        )
        XCTAssertNil(aliceState.pendingPublication)
        XCTAssertNil(bobState.pendingPublication)
        let aliceDevice = rosterDevice(aliceProvisioned, address: aliceAddress)
        let bobDevice = rosterDevice(bobProvisioned, address: bobAddress)

        aliceState = try await engine.establishSessions(
            currentState: aliceState,
            localSender: aliceAddress,
            bundles: [remoteBundle(bobProvisioned, device: bobDevice)]
        )

        let conversationID = "30000000-0000-0000-0000-000000000001"
        let firstClientID = "40000000-0000-0000-0000-000000000001"
        let roster = "v1:sha256:\(String(repeating: "a", count: 64))"
        let first = try await engine.encryptText(
            currentState: aliceState,
            sender: aliceAddress,
            conversationID: conversationID,
            clientMessageID: firstClientID,
            rosterRevision: roster,
            replyToMessageID: nil,
            text: "Offline first, end-to-end encrypted.",
            recipients: [bobDevice]
        )
        aliceState = first.state
        let firstEnvelope = try XCTUnwrap(first.fanout.envelopes.first)
        XCTAssertEqual(firstEnvelope.envelopeType, "signal-prekey-v2")

        let firstDecrypted = try await engine.decryptText(
            currentState: bobState,
            incoming: SecureMessagingInboundEnvelope(
                messageID: "50000000-0000-0000-0000-000000000001",
                clientMessageID: firstClientID,
                conversationID: conversationID,
                rosterRevision: roster,
                replyToMessageID: nil,
                sender: aliceDevice,
                localRecipient: bobAddress,
                envelopeType: firstEnvelope.envelopeType,
                ciphertext: firstEnvelope.ciphertext
            )
        )
        XCTAssertEqual(firstDecrypted.text, "Offline first, end-to-end encrypted.")
        bobState = firstDecrypted.state

        // Serialize both ratchets exactly as SecureLocalStore does, then continue from decoded
        // copies to prove a relaunch does not lose the session.
        aliceState = try JSONDecoder().decode(
            SecureMessagingPersistentState.self,
            from: JSONEncoder().encode(aliceState)
        )
        bobState = try JSONDecoder().decode(
            SecureMessagingPersistentState.self,
            from: JSONEncoder().encode(bobState)
        )

        let replyClientID = "40000000-0000-0000-0000-000000000002"
        let reply = try await engine.encryptText(
            currentState: bobState,
            sender: bobAddress,
            conversationID: conversationID,
            clientMessageID: replyClientID,
            rosterRevision: roster,
            replyToMessageID: "50000000-0000-0000-0000-000000000001",
            text: "Received after restore.",
            recipients: [aliceDevice]
        )
        let replyEnvelope = try XCTUnwrap(reply.fanout.envelopes.first)
        XCTAssertEqual(replyEnvelope.envelopeType, "signal-message-v2")

        let replyDecrypted = try await engine.decryptText(
            currentState: aliceState,
            incoming: SecureMessagingInboundEnvelope(
                messageID: "50000000-0000-0000-0000-000000000002",
                clientMessageID: replyClientID,
                conversationID: conversationID,
                rosterRevision: roster,
                replyToMessageID: "50000000-0000-0000-0000-000000000001",
                sender: bobDevice,
                localRecipient: aliceAddress,
                envelopeType: replyEnvelope.envelopeType,
                ciphertext: replyEnvelope.ciphertext
            )
        )
        XCTAssertEqual(replyDecrypted.text, "Received after restore.")
    }

    func testCommittedFanoutRoundTripsWithoutChangingCiphertext() throws {
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: "40000000-0000-0000-0000-000000000001",
            conversationID: "30000000-0000-0000-0000-000000000001",
            rosterRevision: "v1:sha256:\(String(repeating: "b", count: 64))",
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: [
                SecureMessagingOutboundEnvelope(
                    recipientDeviceID: "20000000-0000-0000-0000-000000000002",
                    envelopeType: "signal-prekey-v2",
                    ciphertext: Data([0, 1, 2, 3, 255])
                ),
            ]
        )

        let decoded = try JSONDecoder().decode(
            SecureMessagingCommittedFanout.self,
            from: JSONEncoder().encode(fanout)
        )

        XCTAssertEqual(decoded, fanout)
        XCTAssertEqual(decoded.envelopes.first?.ciphertext, Data([0, 1, 2, 3, 255]))
    }

    func testPendingPublicationMustBeConfirmedBeforeAnotherProvisioningBatch() async throws {
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)

        do {
            _ = try await engine.provision(from: provisioned.state, preKeyCount: 1)
            XCTFail("A committed pending publication must be republished, not replaced")
        } catch let error as SecureMessagingCryptoError {
            XCTAssertEqual(error, .staleState)
        }
    }

    func testLegacyEnrollmentUpgradesOnlyWhenCurrentServerKeysMatchLocalPrivateRecords() async throws {
        let engine = SecureMessagingCryptoEngine()
        let localAddress = address(
            user: "10000000-0000-0000-0000-000000000010",
            device: "20000000-0000-0000-0000-000000000010"
        )
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let current = try await bind(provisioned, address: localAddress, engine: engine)
        let authoritative = try XCTUnwrap(current.enrollment)

        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var legacyEnrollment = try XCTUnwrap(object["enrollment"] as? [String: Any])
        for key in [
            "signedPreKeyID",
            "signedPreKeySHA256",
            "pqLastResortPreKeyID",
            "pqLastResortPreKeySHA256",
        ] {
            legacyEnrollment.removeValue(forKey: key)
        }
        object["enrollment"] = legacyEnrollment
        let legacy = try JSONDecoder().decode(
            SecureMessagingPersistentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(try XCTUnwrap(legacy.enrollment).hasCompleteKeyCommitment)

        let upgraded = try await engine.bindEnrollment(authoritative, to: legacy)
        XCTAssertEqual(upgraded.enrollment, authoritative)
        XCTAssertTrue(try XCTUnwrap(upgraded.enrollment).hasCompleteKeyCommitment)

        let forged = SecureMessagingEnrollmentBinding(
            userID: authoritative.userID,
            serverDeviceID: authoritative.serverDeviceID,
            signalDeviceID: authoritative.signalDeviceID,
            registrationID: authoritative.registrationID,
            enrollmentEpoch: authoritative.enrollmentEpoch,
            identityKeySHA256: authoritative.identityKeySHA256,
            bundleVersion: authoritative.bundleVersion,
            signedPreKeyID: authoritative.signedPreKeyID,
            signedPreKeySHA256: String(repeating: "0", count: 64),
            pqLastResortPreKeyID: authoritative.pqLastResortPreKeyID,
            pqLastResortPreKeySHA256: authoritative.pqLastResortPreKeySHA256
        )
        do {
            _ = try await engine.bindEnrollment(forged, to: legacy)
            XCTFail("A legacy binding must not trust a server key that lacks its local private record")
        } catch let error as SecureMessagingCryptoError {
            XCTAssertEqual(error, .identityChanged)
        }
    }

    func testLegacyRosterEntriesAreDiscardedWithoutLosingIdentitySessionsOrCursor() throws {
        var state = SecureMessagingPersistentState.empty
        state.identityKeyPair = Data("identity-private-state".utf8)
        state.registrationID = 77
        state.sessions = ["peer:1": Data("ratchet".utf8)]
        state.syncCursor = "cursor-preserved"

        let conversationID = "30000000-0000-0000-0000-000000000077"
        let deviceID = "20000000-0000-0000-0000-000000000077"
        let device = SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: "10000000-0000-0000-0000-000000000077",
                serverDeviceID: deviceID,
                signalDeviceID: 1
            ),
            registrationID: 77,
            identityKeySHA256: String(repeating: "a", count: 64)
        )
        let frozen = SecureMessagingFrozenRosterDevice(
            enrollmentEpoch: 1,
            bundleVersion: 1,
            signedPreKeyID: 1,
            signedPreKeyPublicKey: Data([5]) + Data(repeating: 1, count: 32),
            signedPreKeySHA256: String(repeating: "b", count: 64),
            signedPreKeySignature: Data(repeating: 2, count: 64)
        )
        let valid = SecureMessagingRosterSnapshot(
            use: .current,
            conversationID: conversationID,
            rosterRevision: "v1:sha256:\(String(repeating: "c", count: 64))",
            devices: [device],
            frozenDevices: [deviceID: frozen]
        )
        state.cachedRosters = ["valid": valid]

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        var rosters = try XCTUnwrap(object["cachedRosters"] as? [String: Any])
        var legacy = try XCTUnwrap(rosters["valid"] as? [String: Any])
        legacy.removeValue(forKey: "use")
        legacy.removeValue(forKey: "frozenDevices")
        rosters["legacy"] = legacy
        object["cachedRosters"] = rosters

        let restored = try JSONDecoder().decode(
            SecureMessagingPersistentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(restored.identityKeyPair, state.identityKeyPair)
        XCTAssertEqual(restored.sessions, state.sessions)
        XCTAssertEqual(restored.syncCursor, state.syncCursor)
        XCTAssertEqual(restored.cachedRosters, ["valid": valid])
    }

    private func address(user: String, device: String) -> SecureMessagingAddress {
        SecureMessagingAddress(userID: user, serverDeviceID: device, signalDeviceID: 1)
    }

    private func rosterDevice(
        _ provisioned: SecureMessagingProvisioningResult,
        address: SecureMessagingAddress
    ) -> SecureMessagingRosterDevice {
        SecureMessagingRosterDevice(
            address: address,
            registrationID: provisioned.bundle.registrationID,
            identityKeySHA256: SecureMessagingValidation.sha256Hex(
                provisioned.bundle.identityKey
            )
        )
    }

    private func remoteBundle(
        _ provisioned: SecureMessagingProvisioningResult,
        device: SecureMessagingRosterDevice
    ) -> SecureMessagingRemoteKeyBundle {
        SecureMessagingRemoteKeyBundle(
            device: device,
            identityKey: provisioned.bundle.identityKey,
            signedPreKey: provisioned.bundle.signedPreKey,
            oneTimePreKey: provisioned.bundle.oneTimePreKeys.first,
            pqPreKey: provisioned.bundle.pqPreKeys[0]
        )
    }

    private func bind(
        _ provisioned: SecureMessagingProvisioningResult,
        address: SecureMessagingAddress,
        engine: SecureMessagingCryptoEngine
    ) async throws -> SecureMessagingPersistentState {
        try await engine.bindEnrollment(
            SecureMessagingEnrollmentBinding(
                userID: address.userID,
                serverDeviceID: address.serverDeviceID,
                signalDeviceID: address.signalDeviceID,
                registrationID: provisioned.bundle.registrationID,
                enrollmentEpoch: 1,
                identityKeySHA256: SecureMessagingValidation.sha256Hex(
                    provisioned.bundle.identityKey
                ),
                bundleVersion: 1,
                signedPreKeyID: provisioned.bundle.signedPreKey.id,
                signedPreKeySHA256: SecureMessagingValidation.sha256Hex(
                    provisioned.bundle.signedPreKey.publicKey
                ),
                pqLastResortPreKeyID: provisioned.bundle.pqLastResortPreKey.id,
                pqLastResortPreKeySHA256: SecureMessagingValidation.sha256Hex(
                    provisioned.bundle.pqLastResortPreKey.publicKey
                )
            ),
            to: provisioned.state
        )
    }
}
