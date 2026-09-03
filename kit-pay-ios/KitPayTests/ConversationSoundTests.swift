import AVFoundation
import Foundation
import UserNotifications
import XCTest
@testable import KitPay

final class ConversationSoundTests: XCTestCase {
    private let ownerUserID = "40000000-0000-4000-8000-000000000001"
    private let conversationID = "10000000-0000-4000-8000-000000000001"
    private let visibleAt = Date(timeIntervalSince1970: 1_000)

    func testInitialMessagesFormASilentBaseline() {
        let restored = message(id: 1, createdAt: visibleAt.addingTimeInterval(-10))
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)

        policy.beginVisibility(with: [restored], at: visibleAt)

        XCTAssertFalse(policy.consume([restored], appIsActive: true))
    }

    func testNewIncomingServerMessagePlaysExactlyOnce() {
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)
        policy.beginVisibility(with: [], at: visibleAt)
        let incoming = message(id: 2, createdAt: visibleAt.addingTimeInterval(1))

        XCTAssertTrue(policy.consume([incoming], appIsActive: true))
        XCTAssertFalse(policy.consume([incoming], appIsActive: true))
    }

    func testLateHistoryBackfillNeverPlays() {
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)
        policy.beginVisibility(with: [], at: visibleAt)
        let oldHistory = message(id: 3, createdAt: visibleAt.addingTimeInterval(-60))

        XCTAssertFalse(policy.consume([oldHistory], appIsActive: true))
    }

    func testOutgoingLocalAndUncommittedIncomingMessagesNeverPlay() {
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)
        policy.beginVisibility(with: [], at: visibleAt)
        let outgoing = message(
            id: 4,
            createdAt: visibleAt.addingTimeInterval(1),
            isOutgoing: true
        )
        let uncommitted = message(
            id: 5,
            createdAt: visibleAt.addingTimeInterval(2),
            serverMessageID: nil
        )

        XCTAssertFalse(policy.consume([outgoing, uncommitted], appIsActive: true))
    }

    func testInactiveDeltaIsConsumedWithoutForegroundReplay() {
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)
        policy.beginVisibility(with: [], at: visibleAt)
        let incoming = message(id: 6, createdAt: visibleAt.addingTimeInterval(1))

        XCTAssertFalse(policy.consume([incoming], appIsActive: false))
        XCTAssertFalse(policy.consume([incoming], appIsActive: true))
    }

    func testOtherConversationNeverPlays() {
        var policy = VisibleConversationSoundPolicy(conversationID: conversationID)
        policy.beginVisibility(with: [], at: visibleAt)
        let incoming = message(
            id: 7,
            conversationID: "20000000-0000-4000-8000-000000000002",
            createdAt: visibleAt.addingTimeInterval(1)
        )

        XCTAssertFalse(policy.consume([incoming], appIsActive: true))
    }

    func testCallKitUsesSystemRingtone() {
        XCTAssertNil(CallRingtonePolicy.customSoundName)
    }

    func testAndroidCallToneDefinitionsMatchCallTonePlayer() {
        XCTAssertEqual(AndroidCallToneDefinition.ringbackVolume, 0.70)
        XCTAssertEqual(
            AndroidCallToneDefinition.ringbackSegments,
            [
                .init(durationMilliseconds: 1_000, frequenciesHz: [425]),
                .init(durationMilliseconds: 4_000, frequenciesHz: []),
            ]
        )
        XCTAssertEqual(AndroidCallToneDefinition.disconnectVolume, 0.80)
        XCTAssertEqual(
            AndroidCallToneDefinition.disconnectSegments,
            [
                .init(durationMilliseconds: 125, frequenciesHz: [1_480]),
                .init(durationMilliseconds: 125, frequenciesHz: [1_397]),
                .init(durationMilliseconds: 125, frequenciesHz: [784]),
            ]
        )
        XCTAssertEqual(
            String(decoding: AndroidCallToneRenderer.ringbackWAV.prefix(4), as: UTF8.self),
            "RIFF"
        )
        XCTAssertEqual(AndroidCallToneRenderer.ringbackWAV.count, 441_044)
        XCTAssertEqual(
            String(decoding: AndroidCallToneRenderer.disconnectWAV.prefix(4), as: UTF8.self),
            "RIFF"
        )
        XCTAssertEqual(AndroidCallToneRenderer.disconnectWAV.count, 33_116)
    }

    func testAndroidCallWaitingToneDefinitionAndRendererMatchCallTonePlayer() {
        XCTAssertEqual(AndroidCallToneDefinition.callWaitingVolume, 0.85)
        XCTAssertEqual(AndroidCallToneDefinition.callWaitingRequestDurationMilliseconds, 800)
        XCTAssertEqual(AndroidCallToneDefinition.callWaitingAudibleDurationMilliseconds, 200)
        XCTAssertEqual(AndroidCallToneDefinition.callWaitingRepeatIntervalMilliseconds, 3_500)
        XCTAssertEqual(
            AndroidCallToneDefinition.callWaitingSegments,
            [
                .init(durationMilliseconds: 200, frequenciesHz: [425]),
                .init(durationMilliseconds: 3_300, frequenciesHz: []),
            ]
        )
        XCTAssertEqual(
            AndroidCallToneDefinition.callWaitingSegments
                .map(\.durationMilliseconds)
                .reduce(0, +),
            AndroidCallToneDefinition.callWaitingRepeatIntervalMilliseconds
        )
        XCTAssertEqual(
            String(decoding: AndroidCallToneRenderer.callWaitingWAV.prefix(4), as: UTF8.self),
            "RIFF"
        )
        XCTAssertEqual(AndroidCallToneRenderer.callWaitingWAV.count, 308_744)
    }

    func testAuthenticatedCallWaitingStartsOnceOnActiveCallKitAudioAndClearsExactly() {
        var lifecycle = CallWaitingSoundLifecycle()
        let waitingCallID = "70000000-0000-4000-8000-000000000001"
        let unrelatedCallID = "70000000-0000-4000-8000-000000000002"

        XCTAssertEqual(
            lifecycle.transition(.authenticatedWaitingCall(callID: waitingCallID.uppercased())),
            []
        )
        XCTAssertEqual(lifecycle.waitingCallID, waitingCallID)
        XCTAssertNil(lifecycle.repeatingCallID)
        XCTAssertEqual(
            lifecycle.transition(.callKitAudioActivated),
            [.startRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.authenticatedWaitingCall(callID: waitingCallID)),
            []
        )
        XCTAssertEqual(
            lifecycle.transition(.clearWaitingCall(callID: unrelatedCallID)),
            []
        )
        XCTAssertEqual(lifecycle.repeatingCallID, waitingCallID)
        XCTAssertEqual(
            lifecycle.transition(.clearWaitingCall(callID: waitingCallID.uppercased())),
            [.stopRepeating(callID: waitingCallID)]
        )
        XCTAssertNil(lifecycle.waitingCallID)
        XCTAssertNil(lifecycle.repeatingCallID)
    }

    func testCallWaitingStopsAndResumesAcrossBackgroundAndAudioDeactivationThenResets() {
        var lifecycle = CallWaitingSoundLifecycle()
        let waitingCallID = "70000000-0000-4000-8000-000000000001"

        _ = lifecycle.transition(.authenticatedWaitingCall(callID: waitingCallID))
        XCTAssertEqual(
            lifecycle.transition(.callKitAudioActivated),
            [.startRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.appEnteredBackground),
            [.stopRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(lifecycle.transition(.appEnteredBackground), [])
        XCTAssertEqual(
            lifecycle.transition(.appBecameActive),
            [.startRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.callKitAudioDeactivated),
            [.stopRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.callKitAudioActivated),
            [.startRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(lifecycle.transition(.resetSession), [.stopAll])
        XCTAssertNil(lifecycle.waitingCallID)
        XCTAssertNil(lifecycle.repeatingCallID)
        XCTAssertEqual(lifecycle.transition(.callKitAudioActivated), [])
    }

    func testNewAuthenticatedWaitingCallReplacesOnlyWaitingToneOwnership() {
        var lifecycle = CallWaitingSoundLifecycle()
        let firstCallID = "70000000-0000-4000-8000-000000000001"
        let replacementCallID = "70000000-0000-4000-8000-000000000002"

        _ = lifecycle.transition(.callKitAudioActivated)
        XCTAssertEqual(
            lifecycle.transition(.authenticatedWaitingCall(callID: firstCallID)),
            [.startRepeating(callID: firstCallID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.authenticatedWaitingCall(callID: replacementCallID)),
            [
                .stopRepeating(callID: firstCallID),
                .startRepeating(callID: replacementCallID),
            ]
        )
        XCTAssertEqual(
            lifecycle.transition(.clearWaitingCall(callID: firstCallID)),
            []
        )
        XCTAssertEqual(lifecycle.waitingCallID, replacementCallID)
        XCTAssertEqual(lifecycle.repeatingCallID, replacementCallID)
    }

    func testCallWaitingLifecycleNeverChangesProgressToneOwnership() {
        var progress = CallProgressSoundLifecycle()
        var waiting = CallWaitingSoundLifecycle()
        let activeCallID = "60000000-0000-4000-8000-000000000006"
        let waitingCallID = "70000000-0000-4000-8000-000000000001"

        XCTAssertEqual(
            progress.transition(.serverAcceptedOutgoing(callID: activeCallID)),
            [.startRingback(callID: activeCallID)]
        )
        _ = waiting.transition(.callKitAudioActivated)
        XCTAssertEqual(
            waiting.transition(.authenticatedWaitingCall(callID: waitingCallID)),
            [.startRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(
            waiting.transition(.clearWaitingCall(callID: waitingCallID)),
            [.stopRepeating(callID: waitingCallID)]
        )
        XCTAssertEqual(progress.ringbackCallID, activeCallID)
        XCTAssertEqual(
            progress.transition(.remoteConnected(callID: activeCallID)),
            [.stopRingback(callID: activeCallID)]
        )
        XCTAssertEqual(
            progress.transition(.callEnded(callID: activeCallID)),
            [.playDisconnect(callID: activeCallID)]
        )
    }

    func testOfflineQueuedCallHasNoProgressAudioAdmission() {
        var lifecycle = CallProgressSoundLifecycle()
        let queuedCallID = "60000000-0000-4000-8000-000000000006"

        // Showing an in-memory offline placeholder never invokes a lifecycle transition. If it is
        // cancelled before POST /calls succeeds, even its end event remains silent.
        XCTAssertNil(lifecycle.ringbackCallID)
        XCTAssertEqual(
            lifecycle.transition(.callEnded(callID: queuedCallID)),
            []
        )
        XCTAssertNil(lifecycle.ringbackCallID)
    }

    func testServerAcceptedOutgoingCallRingsUntilRemoteConnectsThenEndsOnce() {
        var lifecycle = CallProgressSoundLifecycle()
        let callID = "60000000-0000-4000-8000-000000000006"

        XCTAssertEqual(
            lifecycle.transition(.serverAcceptedOutgoing(callID: callID.uppercased())),
            [.startRingback(callID: callID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.serverAcceptedOutgoing(callID: callID)),
            []
        )
        XCTAssertEqual(
            lifecycle.transition(.remoteConnected(callID: callID)),
            [.stopRingback(callID: callID)]
        )
        XCTAssertEqual(
            lifecycle.transition(.callEnded(callID: callID)),
            [.playDisconnect(callID: callID)]
        )
        XCTAssertEqual(lifecycle.transition(.callEnded(callID: callID)), [])
    }

    func testDeclinedOutgoingCallStopsRingbackBeforeDisconnectTone() {
        var lifecycle = CallProgressSoundLifecycle()
        let callID = "60000000-0000-4000-8000-000000000006"

        _ = lifecycle.transition(.serverAcceptedOutgoing(callID: callID))

        XCTAssertEqual(
            lifecycle.transition(.callEnded(callID: callID)),
            [
                .stopRingback(callID: callID),
                .playDisconnect(callID: callID),
            ]
        )
    }

    func testIncomingCallOnlyGetsDisconnectToneAfterAnswer() {
        var lifecycle = CallProgressSoundLifecycle()
        let callID = "60000000-0000-4000-8000-000000000006"

        XCTAssertEqual(lifecycle.transition(.callEnded(callID: callID)), [])
        XCTAssertEqual(lifecycle.transition(.incomingAnswered(callID: callID)), [])
        XCTAssertEqual(
            lifecycle.transition(.callEnded(callID: callID)),
            [.playDisconnect(callID: callID)]
        )
    }

    func testSessionReplacementStopsProgressAudioAndForgetsCallOwnership() {
        var lifecycle = CallProgressSoundLifecycle()
        let firstCallID = "60000000-0000-4000-8000-000000000006"

        _ = lifecycle.transition(.serverAcceptedOutgoing(callID: firstCallID))
        XCTAssertEqual(lifecycle.transition(.resetSession), [.stopAll])
        XCTAssertNil(lifecycle.ringbackCallID)
        XCTAssertEqual(lifecycle.transition(.callEnded(callID: firstCallID)), [])
    }

    func testVisibleNotificationPlanIsPrivateDeterministicAndSuppressesOpenThread() {
        let previousMessageID = "30000000-0000-4000-8000-000000000001"
        let openMessageID = "30000000-0000-4000-8000-000000000002"
        let otherMessageID = "30000000-0000-4000-8000-000000000003"
        let otherConversationID = "20000000-0000-4000-8000-000000000002"
        let messages = [
            message(id: 1, createdAt: visibleAt, serverMessageID: previousMessageID),
            message(
                id: 2,
                createdAt: visibleAt.addingTimeInterval(1),
                serverMessageID: openMessageID
            ),
            message(
                id: 3,
                conversationID: otherConversationID,
                createdAt: visibleAt.addingTimeInterval(2),
                serverMessageID: otherMessageID
            ),
            message(
                id: 4,
                conversationID: otherConversationID,
                createdAt: visibleAt.addingTimeInterval(3),
                isOutgoing: true,
                serverMessageID: "30000000-0000-4000-8000-000000000004"
            ),
        ]

        let first = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [previousMessageID],
            messages: messages,
            suppressedConversationID: conversationID,
            ownerUserID: ownerUserID
        )
        let second = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [previousMessageID],
            messages: Array(messages.reversed()),
            suppressedConversationID: conversationID,
            ownerUserID: ownerUserID
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].requestIdentifier.hasPrefix("africa.kit.pay.message."))
        XCTAssertTrue(first[0].threadIdentifier.hasPrefix("africa.kit.pay.thread."))
        XCTAssertFalse(first[0].requestIdentifier.contains(otherMessageID))
        XCTAssertFalse(first[0].threadIdentifier.contains(otherConversationID))
        XCTAssertEqual(first[0].conversationID, otherConversationID)
        XCTAssertEqual(
            first[0].accountFingerprint,
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
    }

    func testVisibleNotificationAuthorizationRequiresGrantedAlerts() {
        XCTAssertTrue(VisibleMessageNotificationAuthorization(
            status: .authorized,
            alertSetting: .enabled
        ).permitsVisibleAlerts)
        XCTAssertTrue(VisibleMessageNotificationAuthorization(
            status: .provisional,
            alertSetting: .enabled
        ).permitsVisibleAlerts)
        XCTAssertFalse(VisibleMessageNotificationAuthorization(
            status: .notDetermined,
            alertSetting: .enabled
        ).permitsVisibleAlerts)
        XCTAssertFalse(VisibleMessageNotificationAuthorization(
            status: .denied,
            alertSetting: .enabled
        ).permitsVisibleAlerts)
        XCTAssertFalse(VisibleMessageNotificationAuthorization(
            status: .authorized,
            alertSetting: .disabled
        ).permitsVisibleAlerts)
    }

    func testVisibleNotificationCollapsesConversationToNewestStableIdentity() throws {
        let firstMessageID = "30000000-0000-4000-8000-000000000005"
        let secondMessageID = "30000000-0000-4000-8000-000000000006"
        let descriptors = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [
                message(id: 5, createdAt: visibleAt, serverMessageID: firstMessageID),
                message(
                    id: 6,
                    createdAt: visibleAt.addingTimeInterval(1),
                    serverMessageID: secondMessageID
                ),
                message(
                    id: 7,
                    createdAt: visibleAt.addingTimeInterval(2),
                    serverMessageID: secondMessageID
                ),
            ],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        )

        XCTAssertEqual(descriptors.count, 1)
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(
            descriptor.requestIdentifier,
            MessageNotificationContract.conversationRequestIdentifier(for: conversationID)
        )
        XCTAssertEqual(Set(descriptors.map(\.threadIdentifier)).count, 1)
        XCTAssertEqual(
            descriptor.version.messageDigest,
            MessageNotificationContract.messageDigest(for: secondMessageID)
        )
        XCTAssertEqual(descriptor.version.sentAtEpochSecond, 1_002)
    }

    func testVisibleNotificationKeepsRequestIdentityButVersionsSuccessiveMessages() throws {
        let first = try XCTUnwrap(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(
                id: 5,
                createdAt: visibleAt,
                serverMessageID: "30000000-0000-4000-8000-000000000005"
            )],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first)
        let second = try XCTUnwrap(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(
                id: 6,
                createdAt: visibleAt.addingTimeInterval(1),
                serverMessageID: "30000000-0000-4000-8000-000000000006"
            )],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first)

        XCTAssertEqual(first.requestIdentifier, second.requestIdentifier)
        XCTAssertEqual(first.threadIdentifier, second.threadIdentifier)
        XCTAssertNotEqual(first.version, second.version)
    }

    func testVisibleNotificationRequiresAnAccountOwnerBinding() {
        XCTAssertTrue(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 8, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: nil
        ).isEmpty)
        XCTAssertTrue(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 8, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: "not-a-user-id"
        ).isEmpty)
    }

    @MainActor
    func testVisibleNotificationCoordinatorDeduplicatesAndContainsNoPlaintext() async {
        let center = FakeVisibleMessageNotificationCenter(
            authorization: VisibleMessageNotificationAuthorization(
                status: .authorized,
                alertSetting: .enabled
            )
        )
        let coordinator = VisibleMessageNotificationCoordinator(
            center: center,
            bundle: .main
        )
        let descriptor = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 7, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first!

        let firstScheduledCount = await coordinator.schedule([descriptor, descriptor])
        let secondScheduledCount = await coordinator.schedule([descriptor])
        XCTAssertEqual(firstScheduledCount, 1)
        XCTAssertEqual(secondScheduledCount, 0)
        XCTAssertEqual(center.requests.count, 1)

        let request = center.requests[0]
        XCTAssertEqual(request.identifier, descriptor.requestIdentifier)
        XCTAssertEqual(request.content.threadIdentifier, descriptor.threadIdentifier)
        XCTAssertEqual(request.content.targetContentIdentifier, descriptor.threadIdentifier)
        XCTAssertEqual(
            request.content.categoryIdentifier,
            MessageNotificationContract.categoryIdentifier
        )
        XCTAssertEqual(request.content.title, VisibleMessageNotificationPolicy.title)
        XCTAssertEqual(request.content.body, VisibleMessageNotificationPolicy.body)
        XCTAssertFalse(request.content.title.contains("Hello"))
        XCTAssertFalse(request.content.body.contains("Hello"))
        XCTAssertFalse(request.content.title.contains(descriptor.conversationID))
        XCTAssertFalse(request.content.body.contains(descriptor.conversationID))
        XCTAssertEqual(request.content.userInfo["type"] as? String, "messaging.local")
        XCTAssertEqual(
            request.content.userInfo["conversation_id"] as? String,
            descriptor.conversationID
        )
        XCTAssertEqual(
            request.content.userInfo["account_fingerprint"] as? String,
            descriptor.accountFingerprint
        )
        XCTAssertEqual(
            request.content.userInfo["message_digest"] as? String,
            descriptor.version.messageDigest
        )
        XCTAssertEqual(request.content.userInfo.count, 8)
        XCTAssertNil(request.content.userInfo["message_id"])
        XCTAssertNotNil(request.content.sound)
    }

    @MainActor
    func testVisibleNotificationCoordinatorSuppressesPublicationUntilOwnershipRecovery() async {
        let center = FakeVisibleMessageNotificationCenter(
            authorization: VisibleMessageNotificationAuthorization(
                status: .authorized,
                alertSetting: .enabled
            )
        )
        let coordinator = VisibleMessageNotificationCoordinator(
            center: center,
            bundle: .main
        )
        let descriptor = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 9, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first!

        coordinator.beginPrivacyQuarantine()
        let blockedCount = await coordinator.schedule([descriptor])
        XCTAssertEqual(blockedCount, 0)
        XCTAssertTrue(center.requests.isEmpty)

        coordinator.resumeAfterOwnershipRecovery()
        let recoveredCount = await coordinator.schedule([descriptor])
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertEqual(center.requests.map(\.identifier), [descriptor.requestIdentifier])
    }

    @MainActor
    func testVisibleNotificationQuarantineStopsStaleRemovalAfterCenterRead() async {
        let staleDescriptor = descriptor(
            conversationOrdinal: 44,
            messageOrdinal: 44,
            sentAt: visibleAt
        )
        let replacementDescriptor = VisibleMessageNotificationDescriptor(
            requestIdentifier: staleDescriptor.requestIdentifier,
            threadIdentifier: staleDescriptor.threadIdentifier,
            conversationID: staleDescriptor.conversationID,
            accountFingerprint: MessageNotificationContract.accountFingerprint(
                for: "90000000-0000-4000-8000-000000000009"
            )!,
            version: staleDescriptor.version
        )
        let center = FakeVisibleMessageNotificationCenter(
            authorization: .init(status: .authorized, alertSetting: .enabled),
            activeRecords: [notificationRecord(replacementDescriptor, location: .delivered)]
        )
        center.suspendNextActiveLookup()
        let coordinator = VisibleMessageNotificationCoordinator(center: center)
        let scheduling = Task { @MainActor in
            await coordinator.schedule([staleDescriptor])
        }

        await center.waitForSuspendedActiveLookup()
        coordinator.beginPrivacyQuarantine()
        center.resumeSuspendedActiveLookup()

        let scheduledCount = await scheduling.value
        XCTAssertEqual(scheduledCount, 0)
        XCTAssertTrue(center.removedPendingIdentifiers.isEmpty)
        XCTAssertTrue(center.removedDeliveredIdentifiers.isEmpty)
        XCTAssertEqual(center.activeRecords.map(\.accountFingerprint), [
            replacementDescriptor.accountFingerprint,
        ])
    }

    func testMessageNotificationCategoryOffersAuthenticatedSecureReply() throws {
        let category = MessageNotificationContract.category

        XCTAssertEqual(category.identifier, MessageNotificationContract.categoryIdentifier)
        XCTAssertEqual(category.actions.count, 1)
        let action = try XCTUnwrap(category.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(action.identifier, MessageNotificationContract.replyActionIdentifier)
        XCTAssertEqual(action.textInputButtonTitle, "Send")
        XCTAssertEqual(action.textInputPlaceholder, "Reply securely")
        XCTAssertTrue(action.options.contains(.authenticationRequired))
        XCTAssertFalse(action.options.contains(.foreground))
    }

    func testClaimablePaymentNotificationCategoryHasNoMoneyMovementAction() {
        let category = ClaimablePaymentNotificationContract.category

        XCTAssertEqual(
            category.identifier,
            ClaimablePaymentNotificationContract.categoryIdentifier
        )
        XCTAssertEqual(category.identifier, "africa.kit.pay.payment.claimable")
        XCTAssertTrue(category.actions.isEmpty)
    }

    func testMessageNotificationTargetResolvesOneExactLocalMessage() throws {
        let target = message(
            id: 4,
            createdAt: visibleAt,
            serverMessageID: "30000000-0000-4000-8000-000000000004"
        )
        let digest = try XCTUnwrap(
            MessageNotificationContract.messageDigest(for: target.serverMessageId!)
        )

        XCTAssertEqual(
            MessageNotificationTargetPolicy.messageID(
                forDigest: digest,
                conversationID: conversationID.uppercased(),
                messages: [target]
            ),
            target.id
        )
        XCTAssertNil(MessageNotificationTargetPolicy.messageID(
            forDigest: digest,
            conversationID: "20000000-0000-4000-8000-000000000002",
            messages: [target]
        ))
        XCTAssertNil(MessageNotificationTargetPolicy.messageID(
            forDigest: digest,
            conversationID: conversationID,
            messages: [target, target]
        ))
        XCTAssertNil(MessageNotificationTargetPolicy.messageID(
            forDigest: "not-a-digest",
            conversationID: conversationID,
            messages: [target]
        ))

        let request = MessageConversationNavigationRequest(
            conversationID: conversationID,
            messageID: target.id
        )
        XCTAssertEqual(request.messageID, target.id)
    }

    func testClaimablePaymentNotificationAcceptsOnlyTheCanonicalTapContract() throws {
        let payload = claimNotificationUserInfo()
        let expectedThread = "wallet-transfer-claim:\(claimID)"
        let action = try XCTUnwrap(ClaimablePaymentNotificationResponsePolicy.action(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: ClaimablePaymentNotificationContract.categoryIdentifier,
            threadIdentifier: expectedThread,
            userInfo: payload
        ))

        XCTAssertEqual(action.notificationID, claimNotificationID)
        XCTAssertEqual(action.claimID, claimID)
        XCTAssertEqual(action.conversationID, conversationID)
        XCTAssertEqual(action.groupPaymentID, claimGroupPaymentID)
        XCTAssertNil(action.accountFingerprint)

        var hostileLink = payload
        hostileLink["deep_link"] = "https://attacker.example/payment/claim?claim_id=\(claimID)"
        XCTAssertNil(claimNotificationAction(hostileLink))

        var wrongClaim = payload
        wrongClaim["claim_id"] = "70000000-0000-4000-8000-000000000099"
        XCTAssertNil(claimNotificationAction(wrongClaim))

        var malformedConversation = payload
        malformedConversation["conversation_id"] = "not-a-uuid"
        XCTAssertNil(claimNotificationAction(malformedConversation))

        var unsupportedType = payload
        unsupportedType["type"] = "wallet.transfer_claim.unknown"
        XCTAssertNil(claimNotificationAction(unsupportedType))

        var malformedExpiry = payload
        malformedExpiry["expires_at"] = "tomorrow"
        XCTAssertNil(claimNotificationAction(malformedExpiry))

        XCTAssertNil(ClaimablePaymentNotificationResponsePolicy.action(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            categoryIdentifier: ClaimablePaymentNotificationContract.categoryIdentifier,
            threadIdentifier: expectedThread,
            userInfo: payload
        ))
    }

    func testClaimablePaymentRoutingRequiresAnAuthenticatedPartyAndExactGroup() throws {
        let peerID = "40000000-0000-4000-8000-000000000002"
        let outsiderID = "40000000-0000-4000-8000-000000000003"
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let claim = claimTransfer(senderID: ownerUserID, recipientID: peerID)
        var group = Conversation(
            id: conversationID,
            title: "Trip",
            participantUserIds: [ownerUserID, peerID],
            unreadCount: 1,
            updatedAt: visibleAt
        )
        group.conversationType = SecureMessagingWire.groupConversationType

        XCTAssertTrue(ClaimablePaymentNotificationRoutingPolicy.authorizesWallet(
            action: action,
            claim: claim,
            currentUserID: ownerUserID
        ))
        XCTAssertFalse(ClaimablePaymentNotificationRoutingPolicy.authorizesWallet(
            action: action,
            claim: claim,
            currentUserID: outsiderID
        ))
        XCTAssertEqual(
            ClaimablePaymentNotificationRoutingPolicy.conversation(
                action: action,
                claim: claim,
                conversations: [group],
                currentUserID: ownerUserID
            ),
            group
        )
        XCTAssertNil(ClaimablePaymentNotificationRoutingPolicy.conversation(
            action: action,
            claim: claim,
            conversations: [group, group],
            currentUserID: ownerUserID
        ))

        var wrongRoster = group
        wrongRoster.participantUserIds = [ownerUserID, outsiderID]
        XCTAssertNil(ClaimablePaymentNotificationRoutingPolicy.conversation(
            action: action,
            claim: claim,
            conversations: [wrongRoster],
            currentUserID: ownerUserID
        ))

        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .transfer,
            paymentRequestId: claimID,
            amountMinor: 100_000,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "Group contribution"
        ))
        let message = LocalMessage(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000099")!,
            serverMessageId: "30000000-0000-4000-8000-000000000099",
            conversationId: conversationID,
            senderId: ownerUserID,
            body: descriptor.encoded,
            createdAt: visibleAt,
            sentAt: visibleAt,
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )
        XCTAssertEqual(
            ClaimablePaymentNotificationRoutingPolicy.targetMessageID(
                action: action,
                claim: claim,
                conversation: group,
                messages: [message]
            ),
            message.id
        )
        XCTAssertNil(ClaimablePaymentNotificationRoutingPolicy.targetMessageID(
            action: action,
            claim: claim,
            conversation: group,
            messages: [message, message]
        ))
    }

    func testClaimablePaymentGroupRoutingAuthorizesTheExactRecipientShareAndMessage() throws {
        let recipientID = "40000000-0000-4000-8000-000000000002"
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let payment = claimGroupPayment(
            senderID: ownerUserID,
            shareClaimID: claimID
        )
        var group = Conversation(
            id: conversationID,
            title: "Trip",
            participantUserIds: [ownerUserID, recipientID],
            unreadCount: 1,
            updatedAt: visibleAt
        )
        group.conversationType = SecureMessagingWire.groupConversationType
        let descriptor = try XCTUnwrap(
            KitGroupPaymentMessage(announcing: payment, recipientUserIds: [])
        )
        let announcement = LocalMessage(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000098")!,
            serverMessageId: "30000000-0000-4000-8000-000000000098",
            conversationId: conversationID,
            senderId: ownerUserID,
            body: descriptor.encoded,
            createdAt: visibleAt,
            sentAt: visibleAt,
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )
        let outcome = LocalMessage(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000097")!,
            serverMessageId: "30000000-0000-4000-8000-000000000097",
            conversationId: conversationID,
            senderId: recipientID,
            body: try XCTUnwrap(
                KitGroupPaymentMessage(
                    outcome: .accepted,
                    groupPaymentId: claimGroupPaymentID
                )
            ).encoded,
            createdAt: visibleAt,
            sentAt: visibleAt,
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )

        XCTAssertTrue(ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
            action: action,
            groupPayment: payment,
            currentUserID: recipientID
        ))
        XCTAssertEqual(
            ClaimablePaymentNotificationRoutingPolicy.conversation(
                action: action,
                groupPayment: payment,
                conversations: [group],
                currentUserID: recipientID
            ),
            group
        )
        XCTAssertEqual(
            ClaimablePaymentNotificationRoutingPolicy.targetMessageID(
                action: action,
                groupPayment: payment,
                conversation: group,
                messages: [outcome, announcement]
            ),
            announcement.id
        )
    }

    func testClaimablePaymentGroupRoutingAuthorizesTheSenderWithoutAnOwnShare() throws {
        let recipientID = "40000000-0000-4000-8000-000000000002"
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let payment = claimGroupPayment(senderID: ownerUserID, shareClaimID: nil)
        var group = Conversation(
            id: conversationID,
            title: "Trip",
            participantUserIds: [ownerUserID, recipientID],
            unreadCount: 1,
            updatedAt: visibleAt
        )
        group.conversationType = SecureMessagingWire.groupConversationType

        XCTAssertTrue(ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
            action: action,
            groupPayment: payment,
            currentUserID: ownerUserID
        ))
        XCTAssertEqual(
            ClaimablePaymentNotificationRoutingPolicy.conversation(
                action: action,
                groupPayment: payment,
                conversations: [group],
                currentUserID: ownerUserID
            ),
            group
        )
    }

    func testClaimablePaymentGroupRoutingRejectsAuthorityMismatchesAndTerminalNotFound() throws {
        let recipientID = "40000000-0000-4000-8000-000000000002"
        let outsiderID = "40000000-0000-4000-8000-000000000003"
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        var group = Conversation(
            id: conversationID,
            title: "Trip",
            participantUserIds: [ownerUserID, recipientID],
            unreadCount: 1,
            updatedAt: visibleAt
        )
        group.conversationType = SecureMessagingWire.groupConversationType

        XCTAssertFalse(ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
            action: action,
            groupPayment: claimGroupPayment(
                senderID: ownerUserID,
                shareClaimID: "70000000-0000-4000-8000-000000000099"
            ),
            currentUserID: recipientID
        ))
        XCTAssertFalse(ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
            action: action,
            groupPayment: claimGroupPayment(
                senderID: ownerUserID,
                shareClaimID: claimID,
                paymentID: "72000000-0000-4000-8000-000000000099"
            ),
            currentUserID: recipientID
        ))
        XCTAssertFalse(ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
            action: action,
            groupPayment: claimGroupPayment(
                senderID: ownerUserID,
                shareClaimID: claimID,
                paymentConversationID: "10000000-0000-4000-8000-000000000099"
            ),
            currentUserID: recipientID
        ))
        XCTAssertNil(ClaimablePaymentNotificationRoutingPolicy.conversation(
            action: action,
            groupPayment: claimGroupPayment(
                senderID: ownerUserID,
                shareClaimID: claimID
            ),
            conversations: [group],
            currentUserID: outsiderID
        ))
        XCTAssertTrue(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
            APIErrorPayload(
                code: "GROUP_PAYMENT_NOT_FOUND",
                message: "The payment was not found.",
                httpStatus: 404
            )
        ))
        XCTAssertFalse(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
            APIErrorPayload(
                code: "GROUP_PAYMENT_TEMPORARILY_UNAVAILABLE",
                message: "Retry later.",
                httpStatus: 503
            )
        ))
    }

    @MainActor
    func testClaimablePaymentDispatcherBuffersAndDeduplicatesOneTap() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()

        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)
        await dispatcher.install { received in
            probe.actions.append(received)
            return .completed
        }
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [action])
    }

    @MainActor
    func testClaimablePaymentTapSurvivesTerminationAndPersistsFirstOwnerBinding() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let boundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: ownerFingerprint)
        )
        // UIKit released the response after this synchronous write, then the process terminated
        // before AppModel could install its handler.
        ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )

        let firstRelaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()
        await firstRelaunch.install { received in
            probe.actions.append(received)
            return received.accountFingerprint == nil
                ? .bindAndContinue(toAccountFingerprint: ownerFingerprint)
                : .retry
        }
        XCTAssertEqual(probe.actions, [action, boundAction])

        // A second process observes the strengthened owner binding, then retires the route only
        // after the handler reports a committed navigation.
        let secondRelaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await secondRelaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [action, boundAction, boundAction])

        let completedRelaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await completedRelaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [action, boundAction, boundAction])
    }

    @MainActor
    func testClaimablePaymentDuplicateCannotEraseDurableOwnerBinding() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let boundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: ownerFingerprint)
        )
        let replacementFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(
                for: "40000000-0000-4000-8000-000000000099"
            )
        )
        let replacementBoundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: replacementFingerprint)
        )

        ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )
        // This actor initialized while the cold-launch record was still unbound.
        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            boundAction,
            defaults: defaults
        )
        // Neither an unbound repeated callback nor a conflicting later owner may weaken or
        // replace the first binding.
        ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )
        ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            replacementBoundAction,
            defaults: defaults
        )

        let probe = ClaimablePaymentNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            return .completed
        }

        XCTAssertEqual(probe.actions, [boundAction])
    }

    @MainActor
    func testClaimablePaymentDispatcherRetriesFailureAndRetiresInvalidOwner() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let boundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: ownerFingerprint)
        )
        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            return probe.actions.count == 1 ? .retry : .invalidated
        }

        await dispatcher.dispatch(boundAction)
        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [boundAction, boundAction])
        let nextLaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [boundAction, boundAction])
    }

    func testClaimablePaymentLookupFailurePolicyRetiresOnlyTerminalHTTPResults() {
        for status in [403, 404, 410] {
            XCTAssertTrue(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
                APIClientError.httpStatus(status)
            ))
            XCTAssertTrue(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
                APIClientError.invalidPayload(status: status)
            ))
            XCTAssertTrue(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
                APIClientError.httpResponse(status: status, retryAfter: nil)
            ))
            XCTAssertTrue(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
                APIErrorPayload(code: "CLAIM_UNAVAILABLE", message: "Unavailable", httpStatus: status)
            ))
        }

        for status in [0, 401, 408, 422, 429, 500, 503] {
            XCTAssertFalse(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
                APIClientError.httpStatus(status)
            ))
        }
        XCTAssertFalse(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
            APIClientError.invalidResponse
        ))
        XCTAssertFalse(ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(
            URLError(.notConnectedToInternet)
        ))
    }

    func testClaimablePaymentCapabilityPolicyDistinguishesUnknownFromWithdrawal() {
        func capabilities(_ features: [String: Bool?]?) -> CapabilitiesDTO {
            CapabilitiesDTO(
                apiVersion: "v1",
                currency: CurrencyDTO(code: "UGX", scale: "2"),
                features: features,
                authentication: nil
            )
        }

        XCTAssertEqual(
            ClaimablePaymentNotificationCapabilityPolicy.readiness(capabilities: nil),
            .awaitingAuthority
        )
        XCTAssertEqual(
            ClaimablePaymentNotificationCapabilityPolicy.readiness(
                capabilities: capabilities(nil)
            ),
            .awaitingAuthority
        )
        XCTAssertEqual(
            ClaimablePaymentNotificationCapabilityPolicy.readiness(
                capabilities: capabilities(["wallets": true, "internal_transfers": true])
            ),
            .awaitingAuthority
        )
        XCTAssertEqual(
            ClaimablePaymentNotificationCapabilityPolicy.readiness(
                capabilities: capabilities([
                    "wallets": true,
                    "internal_transfers": true,
                    "claimable_transfers": nil,
                ])
            ),
            .awaitingAuthority
        )
        for withdrawn in ["wallets", "internal_transfers", "claimable_transfers"] {
            var features: [String: Bool?] = [
                "wallets": true,
                "internal_transfers": true,
                "claimable_transfers": true,
            ]
            features[withdrawn] = false
            XCTAssertEqual(
                ClaimablePaymentNotificationCapabilityPolicy.readiness(
                    capabilities: capabilities(features)
                ),
                .withdrawn
            )
        }
        XCTAssertEqual(
            ClaimablePaymentNotificationCapabilityPolicy.readiness(
                capabilities: capabilities([
                    "wallets": true,
                    "internal_transfers": true,
                    "claimable_transfers": true,
                ])
            ),
            .enabled
        )
    }

    @MainActor
    func testClaimablePaymentCapabilityWakeIsReplayedAfterActiveRetryUnwinds() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let boundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: ownerFingerprint)
        )
        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            if probe.actions.count == 1 {
                await probe.suspendHandler()
                return .retry
            }
            return .completed
        }

        let dispatch = Task { await dispatcher.dispatch(boundAction) }
        await probe.waitForSuspendedHandler()
        // Models an authoritative capability refresh completing while the original nil-capability
        // handler is still suspended. The wake must run once after `.retry` restores the row.
        await dispatcher.replayPending()
        probe.resumeHandler()
        await dispatch.value

        XCTAssertEqual(probe.actions, [boundAction, boundAction])
        let nextLaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [boundAction, boundAction])
    }

    @MainActor
    func testAccountBoundaryFencesAnInFlightClaimNotificationRetry() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let boundAction = try XCTUnwrap(
            action.bound(toAccountFingerprint: ownerFingerprint)
        )
        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            await probe.suspendHandler()
            return .retry
        }

        let dispatch = Task { await dispatcher.dispatch(boundAction) }
        await probe.waitForSuspendedHandler()
        await dispatcher.invalidateAllPendingActions()
        probe.resumeHandler()
        await dispatch.value

        let nextLaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [boundAction])
    }

    @MainActor
    func testAccountBoundaryStopsClaimReplayBeyondCompletedDeduplicationWindow() async throws {
        let suiteName = "ConversationSoundTests.claim-notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ownerFingerprint = try XCTUnwrap(
            MessageNotificationContract.accountFingerprint(for: ownerUserID)
        )
        let actions = (0 ..< 130).map { _ in
            ClaimablePaymentNotificationAction(
                notificationID: UUID().uuidString.lowercased(),
                claimID: UUID().uuidString.lowercased(),
                conversationID: nil,
                groupPaymentID: nil,
                accountFingerprint: ownerFingerprint
            )
        }
        for action in actions {
            ClaimablePaymentNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
                action,
                defaults: defaults
            )
        }

        let dispatcher = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        let probe = ClaimablePaymentNotificationActionProbe()
        let replay = Task {
            await dispatcher.install { received in
                probe.actions.append(received)
                if probe.actions.count == 1 { await probe.suspendHandler() }
                return .retry
            }
        }
        await probe.waitForSuspendedHandler()
        await dispatcher.invalidateAllPendingActions()
        probe.resumeHandler()
        await replay.value

        XCTAssertEqual(probe.actions, [actions[0]])
        let nextLaunch = ClaimablePaymentNotificationActionDispatcher(defaults: defaults)
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [actions[0]])
    }

    func testMessageNotificationResponseRoutesTapAndTrimsInlineReply() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let userInfo = notificationUserInfo(descriptor)

        let open = try XCTUnwrap(MessageNotificationResponsePolicy.action(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: descriptor.requestIdentifier,
            categoryIdentifier: MessageNotificationContract.categoryIdentifier,
            threadIdentifier: descriptor.threadIdentifier,
            userInfo: userInfo
        ))
        XCTAssertEqual(open.conversationID, conversationID)
        XCTAssertEqual(open.accountFingerprint, descriptor.accountFingerprint)
        XCTAssertEqual(open.kind, .open)

        let reply = try XCTUnwrap(MessageNotificationResponsePolicy.action(
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            requestIdentifier: descriptor.requestIdentifier,
            categoryIdentifier: MessageNotificationContract.categoryIdentifier,
            threadIdentifier: descriptor.threadIdentifier,
            userInfo: userInfo,
            userText: "  On my way  \n"
        ))
        XCTAssertEqual(reply.kind, .reply("On my way"))
        XCTAssertEqual(reply.messageDigest, descriptor.version.messageDigest)
    }

    func testValidatedNotificationTapSurvivesColdLaunchPrivacyQuarantine() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))

        let disposition = NotificationResponseDispositionPolicy.disposition(
            messageAction: action,
            claimAction: nil,
            registrationEnabled: false,
            privacyQuarantineActive: true
        )

        XCTAssertEqual(disposition, .message(action))
        XCTAssertTrue(disposition.completesBeforeRouting)
    }

    func testValidatedClaimTapSurvivesColdLaunchPrivacyQuarantine() throws {
        let action = try XCTUnwrap(claimNotificationAction(claimNotificationUserInfo()))

        let disposition = NotificationResponseDispositionPolicy.disposition(
            messageAction: nil,
            claimAction: action,
            registrationEnabled: false,
            privacyQuarantineActive: true
        )

        XCTAssertEqual(disposition, .claim(action))
        XCTAssertTrue(disposition.completesBeforeRouting)
    }

    func testOpaqueNotificationCannotCrossColdLaunchPrivacyQuarantine() {
        XCTAssertEqual(
            NotificationResponseDispositionPolicy.disposition(
                messageAction: nil,
                claimAction: nil,
                registrationEnabled: false,
                privacyQuarantineActive: true
            ),
            .ignore
        )
        XCTAssertEqual(
            NotificationResponseDispositionPolicy.disposition(
                messageAction: nil,
                claimAction: nil,
                registrationEnabled: true,
                privacyQuarantineActive: false
            ),
            .opaqueWake
        )
    }

    func testInlineReplyKeepsSystemLifetimeUntilDurableQueueingFinishes() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: notificationUserInfo(descriptor),
            userText: "On my way"
        ))
        let disposition = NotificationResponseDisposition.message(action)

        XCTAssertFalse(disposition.completesBeforeRouting)
    }

    func testMessageNotificationResponseAcceptsLegacyFiveKeyNotification() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let legacyRequestIdentifier = try XCTUnwrap(
            MessageNotificationContract.messageIdentifier(
                for: "30000000-0000-4000-8000-000000000009"
            )
        )
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            requestIdentifier: legacyRequestIdentifier,
            userInfo: legacyNotificationUserInfo(descriptor)
        ))

        XCTAssertEqual(action.conversationID, descriptor.conversationID)
        XCTAssertNil(action.messageDigest)
    }

    func testMessageNotificationResponseFailsClosedForUntrustedOrInvalidRoutes() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let exact = notificationUserInfo(descriptor)

        var decorated = exact
        decorated["sender_name"] = "Leaked sender"
        XCTAssertNil(notificationAction(descriptor, userInfo: decorated))

        var wrongConversation = exact
        wrongConversation["conversation_id"] = "not-a-uuid"
        XCTAssertNil(notificationAction(descriptor, userInfo: wrongConversation))

        XCTAssertNil(notificationAction(
            descriptor,
            categoryIdentifier: "provider.supplied.category",
            userInfo: exact
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            threadIdentifier: "provider.supplied.thread",
            userInfo: exact
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: exact
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            requestIdentifier: "africa.kit.pay.message.not-a-digest",
            userInfo: exact
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            requestIdentifier: MessageNotificationContract.messageIdentifier(
                for: "30000000-0000-4000-8000-000000000008"
            ),
            userInfo: exact
        ))
        var malformedFreshness = exact
        malformedFreshness["sent_at_nanosecond"] = 1_000_000_000
        XCTAssertNil(notificationAction(descriptor, userInfo: malformedFreshness))
        XCTAssertNil(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: exact,
            userText: "   \n"
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: exact,
            userText: "unsafe\u{0}reply"
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: exact,
            userText: "  KITPAY1:v=1&a=sent"
        ))
        XCTAssertNil(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: exact,
            userText: String(
                repeating: "a",
                count: MessageNotificationContract.maximumReplyBytes + 1
            )
        ))
    }

    @MainActor
    func testMessageNotificationDispatcherBuffersColdLaunchAndDeduplicatesResponse() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()

        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)
        await dispatcher.install { received in
            probe.actions.append(received)
            return .completed
        }
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [action])
    }

    @MainActor
    func testMessageNotificationDispatcherRetriesOnlyAnUncompletedResponse() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            return probe.actions.count > 1 ? .completed : .retry
        }

        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [action, action])
    }

    @MainActor
    func testColdLaunchNotificationSurvivesTerminationAndRoutesAfterSyncHydration() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))

        // UIKit delivered the tap, but the process terminated before AppModel installed its
        // handler. A newly constructed dispatcher represents the next cold launch.
        MessageNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )

        let relaunchedProcess = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()
        await relaunchedProcess.install { received in
            probe.actions.append(received)
            guard probe.conversationAvailable else {
                probe.syncAttempts += 1
                return .retry
            }
            return .completed
        }

        XCTAssertEqual(probe.actions, [action])
        XCTAssertEqual(probe.syncAttempts, 1)

        probe.conversationAvailable = true
        await relaunchedProcess.replayPending()
        XCTAssertEqual(probe.actions, [action, action])

        let nextLaunch = MessageNotificationActionDispatcher(defaults: defaults)
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertEqual(probe.actions, [action, action])
    }

    @MainActor
    func testAuthenticatedOwnerInvalidationRetiresDurableNotificationRoute() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let firstLaunch = MessageNotificationActionDispatcher(defaults: defaults)
        await firstLaunch.dispatch(action)
        await firstLaunch.install { _ in .invalidated }

        let nextLaunch = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }

        XCTAssertTrue(probe.actions.isEmpty)
    }

    @MainActor
    func testExistingDispatcherReloadsSynchronousNotificationRoute() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()

        MessageNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )
        await dispatcher.install { received in
            probe.actions.append(received)
            return .completed
        }

        XCTAssertEqual(probe.actions, [action])
    }

    @MainActor
    func testCompletedDuplicateTapDoesNotSurviveAnotherLaunch() async throws {
        let suiteName = "ConversationSoundTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher(defaults: defaults)
        await dispatcher.install { _ in .completed }
        await dispatcher.dispatch(action)

        MessageNotificationActionDispatcher.persistBeforeCompletingSystemResponse(
            action,
            defaults: defaults
        )
        await dispatcher.dispatch(action)

        let nextLaunch = MessageNotificationActionDispatcher(defaults: defaults)
        let probe = MessageNotificationActionProbe()
        await nextLaunch.install { received in
            probe.actions.append(received)
            return .completed
        }
        XCTAssertTrue(probe.actions.isEmpty)
    }

    func testNotificationReplyUsesAStableAccountBoundClientMessageID() throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let userInfo = notificationUserInfo(descriptor)
        let first = try XCTUnwrap(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: userInfo,
            userText: "On my way"
        ))
        let replay = try XCTUnwrap(notificationAction(
            descriptor,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: userInfo,
            userText: "On my way"
        ))

        XCTAssertEqual(first.replyClientMessageID, replay.replyClientMessageID)
        let clientMessageID = try XCTUnwrap(first.replyClientMessageID)
        let versionIndex = clientMessageID.uuidString.index(
            clientMessageID.uuidString.startIndex,
            offsetBy: 14
        )
        XCTAssertEqual(String(clientMessageID.uuidString[versionIndex]), "8")
    }

    func testSuccessiveConversationNotificationsUseDistinctReplyIdentities() throws {
        let first = try XCTUnwrap(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(
                id: 5,
                createdAt: visibleAt,
                serverMessageID: "30000000-0000-4000-8000-000000000005"
            )],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first)
        let second = try XCTUnwrap(VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(
                id: 6,
                createdAt: visibleAt.addingTimeInterval(1),
                serverMessageID: "30000000-0000-4000-8000-000000000006"
            )],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first)
        let firstAction = try XCTUnwrap(notificationAction(
            first,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: notificationUserInfo(first),
            userText: "First reply"
        ))
        let secondAction = try XCTUnwrap(notificationAction(
            second,
            actionIdentifier: MessageNotificationContract.replyActionIdentifier,
            userInfo: notificationUserInfo(second),
            userText: "Second reply"
        ))

        XCTAssertEqual(first.requestIdentifier, second.requestIdentifier)
        XCTAssertNotEqual(firstAction.deduplicationKey, secondAction.deduplicationKey)
        XCTAssertNotEqual(firstAction.replyClientMessageID, secondAction.replyClientMessageID)
    }

    func testMessageNotificationConversationRequiresOneAuthenticatedPeer() {
        let peer = "40000000-0000-4000-8000-000000000002"
        let conversation = Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: [ownerUserID, peer],
            unreadCount: 1,
            updatedAt: visibleAt
        )

        XCTAssertEqual(
            MessageNotificationConversationPolicy.conversation(
                id: conversationID,
                in: [conversation]
            ),
            conversation
        )
        XCTAssertNil(MessageNotificationConversationPolicy.conversation(
            id: conversationID,
            in: [conversation, conversation]
        ))
        XCTAssertEqual(
            MessageNotificationConversationPolicy.recipientUserID(
                in: conversation,
                currentUserID: ownerUserID
            ),
            peer
        )
        XCTAssertNil(MessageNotificationConversationPolicy.recipientUserID(
            in: Conversation(
                id: conversationID,
                title: "Invalid",
                participantUserIds: [ownerUserID, peer, "not-a-uuid"],
                unreadCount: 1,
                updatedAt: visibleAt
            ),
            currentUserID: ownerUserID
        ))
        XCTAssertNil(MessageNotificationConversationPolicy.recipientUserID(
            in: Conversation(
                id: conversationID,
                title: "Duplicate participant",
                participantUserIds: [ownerUserID, ownerUserID, peer],
                unreadCount: 1,
                updatedAt: visibleAt
            ),
            currentUserID: ownerUserID
        ))
    }

    @MainActor
    func testVisibleNotificationCoordinatorHonorsDeniedAuthorizationAndEqualVersion() async {
        let descriptor = VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 8, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first!
        let denied = FakeVisibleMessageNotificationCenter(
            authorization: VisibleMessageNotificationAuthorization(
                status: .denied,
                alertSetting: .disabled
            )
        )
        let deniedScheduledCount = await VisibleMessageNotificationCoordinator(
            center: denied
        ).schedule([descriptor])
        XCTAssertEqual(deniedScheduledCount, 0)
        XCTAssertTrue(denied.requests.isEmpty)

        let existing = FakeVisibleMessageNotificationCenter(
            authorization: VisibleMessageNotificationAuthorization(
                status: .authorized,
                alertSetting: .enabled
            ),
            activeRecords: [notificationRecord(descriptor, location: .delivered)]
        )
        let existingScheduledCount = await VisibleMessageNotificationCoordinator(
            center: existing
        ).schedule([descriptor])
        XCTAssertEqual(existingScheduledCount, 0)
        XCTAssertTrue(existing.requests.isEmpty)
    }

    @MainActor
    func testVisibleNotificationCoordinatorRejectsStaleCatchUp() async {
        let older = descriptor(
            conversationOrdinal: 1,
            messageOrdinal: 1,
            sentAt: visibleAt
        )
        let newer = descriptor(
            conversationOrdinal: 1,
            messageOrdinal: 2,
            sentAt: visibleAt.addingTimeInterval(1)
        )
        let center = FakeVisibleMessageNotificationCenter(
            authorization: .init(status: .authorized, alertSetting: .enabled),
            activeRecords: [notificationRecord(newer, location: .delivered)]
        )

        let scheduled = await VisibleMessageNotificationCoordinator(
            center: center
        ).schedule([older])

        XCTAssertEqual(scheduled, 0)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.activeRecords.map(\.version), [newer.version])
        XCTAssertTrue(center.removedDeliveredIdentifiers.isEmpty)
    }

    @MainActor
    func testVisibleNotificationCoordinatorReplacesPendingAndDeliveredOlderRows() async {
        let older = descriptor(
            conversationOrdinal: 1,
            messageOrdinal: 1,
            sentAt: visibleAt
        )
        let newer = descriptor(
            conversationOrdinal: 1,
            messageOrdinal: 2,
            sentAt: visibleAt.addingTimeInterval(1)
        )
        let center = FakeVisibleMessageNotificationCenter(
            authorization: .init(status: .authorized, alertSetting: .enabled),
            activeRecords: [
                notificationRecord(older, location: .pending),
                notificationRecord(older, location: .delivered),
            ]
        )

        let scheduled = await VisibleMessageNotificationCoordinator(
            center: center
        ).schedule([newer])

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(center.activeRecords.count, 1)
        XCTAssertEqual(center.activeRecords.first?.version, newer.version)
        XCTAssertEqual(center.removedPendingIdentifiers, [older.requestIdentifier])
        XCTAssertEqual(center.removedDeliveredIdentifiers, [older.requestIdentifier])
    }

    @MainActor
    func testVisibleNotificationCoordinatorBoundsPendingAndDeliveredQuota() async {
        let existingDescriptors = (1 ... 32).map {
            descriptor(
                conversationOrdinal: $0,
                messageOrdinal: $0,
                sentAt: visibleAt.addingTimeInterval(Double($0))
            )
        }
        let center = FakeVisibleMessageNotificationCenter(
            authorization: .init(status: .authorized, alertSetting: .enabled),
            activeRecords: existingDescriptors.enumerated().map { index, descriptor in
                notificationRecord(
                    descriptor,
                    location: index.isMultiple(of: 2) ? .pending : .delivered
                )
            }
        )
        let incoming = descriptor(
            conversationOrdinal: 33,
            messageOrdinal: 33,
            sentAt: visibleAt.addingTimeInterval(33)
        )

        let scheduled = await VisibleMessageNotificationCoordinator(
            center: center
        ).schedule([incoming])

        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(
            center.activeRecords.count,
            VisibleMessageNotificationPublicationPolicy.maximumActiveNotifications
        )
        XCTAssertEqual(Set(center.activeRecords.map(\.threadIdentifier)).count, 32)
        XCTAssertFalse(center.activeRecords.contains {
            $0.threadIdentifier == existingDescriptors[0].threadIdentifier
        })
        XCTAssertTrue(center.activeRecords.contains {
            $0.threadIdentifier == incoming.threadIdentifier
        })
    }

    func testBundledNotificationSoundIsShortLinearPCMCAF() async throws {
        XCTAssertNil(VisibleMessageNotificationPolicy.bundledCustomSoundName(
            in: Bundle(for: ConversationSoundTests.self)
        ))
        XCTAssertEqual(
            VisibleMessageNotificationPolicy.bundledCustomSoundName(in: .main),
            "knock_brush.caf"
        )
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "knock_brush", withExtension: "caf")
        )
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "caff")
        XCTAssertGreaterThan(bytes.count, 32)
        XCTAssertEqual(String(decoding: bytes[28..<32], as: UTF8.self), "lpcm")

        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertLessThanOrEqual(duration.seconds, 30)
    }

    private func message(
        id: UInt8,
        conversationID: String? = nil,
        createdAt: Date,
        isOutgoing: Bool = false,
        serverMessageID: String? = "30000000-0000-4000-8000-000000000003"
    ) -> LocalMessage {
        let uuid = UUID(
            uuidString: "50000000-0000-4000-8000-00000000000\(id)"
        )!
        return LocalMessage(
            id: uuid,
            serverMessageId: serverMessageID,
            conversationId: conversationID ?? self.conversationID,
            senderId: "40000000-0000-4000-8000-000000000004",
            body: "Hello",
            createdAt: createdAt,
            sentAt: createdAt,
            state: isOutgoing ? .sent : .received,
            failureReason: nil,
            isOutgoing: isOutgoing
        )
    }

    private func notificationDescriptor() -> VisibleMessageNotificationDescriptor? {
        VisibleMessageNotificationPolicy.descriptors(
            previousServerMessageIDs: [],
            messages: [message(id: 9, createdAt: visibleAt)],
            suppressedConversationID: nil,
            ownerUserID: ownerUserID
        ).first
    }

    private func descriptor(
        conversationOrdinal: Int,
        messageOrdinal: Int,
        sentAt: Date
    ) -> VisibleMessageNotificationDescriptor {
        let conversationID = String(
            format: "10000000-0000-4000-8000-%012d",
            conversationOrdinal
        )
        let messageID = String(
            format: "30000000-0000-4000-8000-%012d",
            messageOrdinal
        )
        return VisibleMessageNotificationDescriptor(
            requestIdentifier: MessageNotificationContract.conversationRequestIdentifier(
                for: conversationID
            )!,
            threadIdentifier: MessageNotificationContract.threadIdentifier(
                for: conversationID
            )!,
            conversationID: conversationID,
            accountFingerprint: MessageNotificationContract.accountFingerprint(
                for: ownerUserID
            )!,
            version: MessageNotificationContract.messageVersion(
                for: messageID,
                sentAt: sentAt
            )!
        )
    }

    private func notificationRecord(
        _ descriptor: VisibleMessageNotificationDescriptor,
        location: VisibleMessageNotificationRecord.Location
    ) -> VisibleMessageNotificationRecord {
        VisibleMessageNotificationRecord(
            requestIdentifier: descriptor.requestIdentifier,
            threadIdentifier: descriptor.threadIdentifier,
            conversationID: descriptor.conversationID,
            accountFingerprint: descriptor.accountFingerprint,
            version: descriptor.version,
            location: location,
            deliveredAt: location == .delivered
                ? Date(timeIntervalSince1970: TimeInterval(
                    descriptor.version.sentAtEpochSecond
                ))
                : nil
        )
    }

    private func notificationUserInfo(
        _ descriptor: VisibleMessageNotificationDescriptor
    ) -> [AnyHashable: Any] {
        var userInfo = legacyNotificationUserInfo(descriptor)
        userInfo["message_digest"] = descriptor.version.messageDigest
        userInfo["sent_at_epoch_second"] = descriptor.version.sentAtEpochSecond
        userInfo["sent_at_nanosecond"] = descriptor.version.sentAtNanosecond
        return userInfo
    }

    private func legacyNotificationUserInfo(
        _ descriptor: VisibleMessageNotificationDescriptor
    ) -> [AnyHashable: Any] {
        [
            "type": MessageNotificationContract.localType,
            "scope": MessageNotificationContract.messagingScope,
            "conversation_id": descriptor.conversationID,
            "account_fingerprint": descriptor.accountFingerprint,
            "thread_identifier": descriptor.threadIdentifier,
        ]
    }

    private func notificationAction(
        _ descriptor: VisibleMessageNotificationDescriptor,
        categoryIdentifier: String = MessageNotificationContract.categoryIdentifier,
        threadIdentifier: String? = nil,
        actionIdentifier: String = UNNotificationDefaultActionIdentifier,
        requestIdentifier: String? = nil,
        userInfo: [AnyHashable: Any],
        userText: String? = nil
    ) -> MessageNotificationAction? {
        MessageNotificationResponsePolicy.action(
            actionIdentifier: actionIdentifier,
            requestIdentifier: requestIdentifier ?? descriptor.requestIdentifier,
            categoryIdentifier: categoryIdentifier,
            threadIdentifier: threadIdentifier ?? descriptor.threadIdentifier,
            userInfo: userInfo,
            userText: userText
        )
    }

    private var claimID: String { "70000000-0000-4000-8000-000000000001" }
    private var claimNotificationID: String { "71000000-0000-4000-8000-000000000001" }
    private var claimGroupPaymentID: String { "72000000-0000-4000-8000-000000000001" }

    private func claimNotificationUserInfo() -> [AnyHashable: Any] {
        [
            "type": "wallet.transfer_claim.opened",
            "action": "open_transfer_claim",
            "notification_id": claimNotificationID,
            "claim_id": claimID,
            "conversation_id": conversationID,
            "group_payment_id": claimGroupPaymentID,
            "notification_tag": "wallet-transfer-claim:\(claimID)",
            "deep_link": "kitwallet://payment/claim?claim_id=\(claimID)",
            "expires_at": "2026-09-04T10:15:30.123Z",
        ]
    }

    private func claimNotificationAction(
        _ userInfo: [AnyHashable: Any]
    ) -> ClaimablePaymentNotificationAction? {
        ClaimablePaymentNotificationResponsePolicy.action(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: ClaimablePaymentNotificationContract.categoryIdentifier,
            threadIdentifier: "wallet-transfer-claim:\(claimID)",
            userInfo: userInfo
        )
    }

    private func claimTransfer(
        senderID: String,
        recipientID: String
    ) -> TransferAcceptanceDTO {
        try! JSONDecoder().decode(
            TransferAcceptanceDTO.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": claimID,
                "transaction_id": "73000000-0000-4000-8000-000000000001",
                "status": "pending",
                "amount": "1000.00",
                "currency": ["code": "UGX", "scale": "2"],
                "sender": ["id": senderID],
                "recipient": ["id": recipientID],
                "note": "Group contribution",
                "can_accept": true,
                "can_reject": true,
                "can_reverse": true,
            ])
        )
    }

    private func claimGroupPayment(
        senderID: String,
        shareClaimID: String?,
        paymentID: String? = nil,
        paymentConversationID: String? = nil
    ) -> GroupPaymentDTO {
        var payload: [String: Any] = [
            "id": paymentID ?? claimGroupPaymentID,
            "conversation_id": paymentConversationID ?? conversationID,
            "split_mode": "even",
            "audience": "all",
            "currency": ["code": "UGX", "scale": "2"],
            "recipient_count": 1,
            "total_amount": "1000.00",
            "sender": ["id": senderID, "name": "Sender"],
            "status": "pending",
            "pending_count": 1,
            "accepted_count": 0,
            "returned_count": 0,
            "can_reverse_unclaimed": true,
            "recipients": [],
        ]
        if let shareClaimID {
            payload["your_share"] = [
                "amount": "1000.00",
                "status": "pending",
                "claim_id": shareClaimID,
                "can_accept": true,
                "can_reject": true,
            ]
        }
        return try! JSONDecoder().decode(
            GroupPaymentDTO.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }
}

@MainActor
private final class ClaimablePaymentNotificationActionProbe {
    var actions: [ClaimablePaymentNotificationAction] = []
    private var handlerContinuation: CheckedContinuation<Void, Never>?
    private var handlerWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendHandler() async {
        await withCheckedContinuation { continuation in
            handlerContinuation = continuation
            let waiters = handlerWaiters
            handlerWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitForSuspendedHandler() async {
        if handlerContinuation != nil { return }
        await withCheckedContinuation { continuation in
            handlerWaiters.append(continuation)
        }
    }

    func resumeHandler() {
        let continuation = handlerContinuation
        handlerContinuation = nil
        continuation?.resume()
    }
}

final class ChatPresentationPolicyTests: XCTestCase {
    func testChatHeaderKeepsAvatarInsideBackButtonSizedControl() {
        XCTAssertEqual(
            ConversationHeaderLayoutPolicy.avatarControlDiameter,
            ConversationHeaderLayoutPolicy.navigationControlDiameter
        )
        XCTAssertEqual(ConversationHeaderLayoutPolicy.navigationControlDiameter, 44)
        XCTAssertLessThan(
            ConversationHeaderLayoutPolicy.avatarImageDiameter,
            ConversationHeaderLayoutPolicy.avatarControlDiameter
        )
        XCTAssertEqual(ConversationHeaderLayoutPolicy.nameLineLimit, 1)
        XCTAssertGreaterThan(ConversationHeaderLayoutPolicy.identitySpacing, 0)
    }

    func testChatCallControlsUseACompactAccessibleLayout() {
        // Separate circular glass lenses stay unambiguous while using the requested tighter gap.
        XCTAssertEqual(
            ConversationHeaderLayoutPolicy.callControlSpacing,
            KitControlMetrics.controlSpacing
        )
        XCTAssertGreaterThan(ConversationHeaderLayoutPolicy.callControlSpacing, 0)
        XCTAssertGreaterThanOrEqual(
            ConversationHeaderLayoutPolicy.navigationControlDiameter,
            44
        )
        XCTAssertLessThan(
            ConversationHeaderLayoutPolicy.callControlSpacing,
            ConversationHeaderLayoutPolicy.identitySpacing
        )
    }

    func testChatHeaderKeepsIdentityReadableWhileTighteningOnlyCallControls() {
        XCTAssertEqual(
            ConversationHeaderLayoutPolicy.identitySpacing,
            ConversationHeaderLayoutPolicy.baseIdentitySpacing,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversationHeaderLayoutPolicy.callControlSpacing,
            2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ConversationHeaderLayoutPolicy.avatarControlDiameter,
            KitControlMetrics.barControlDiameter
        )
    }

    func testChatHeaderNameTruncatesWithAnEllipsisRatherThanBeingClipped() {
        XCTAssertEqual(ConversationHeaderLayoutPolicy.nameLineLimit, 1)
        // Back button, photo lens, name, and the call capsule must all fit the narrowest
        // supported iPhone width without the bar having to clip or drop a control.
        XCTAssertLessThan(
            ConversationHeaderLayoutPolicy.maximumNameWidth
                + ConversationHeaderLayoutPolicy.reservedBarWidth,
            ConversationHeaderLayoutPolicy.narrowestSupportedBarWidth
        )
        // The cap still has to be generous enough to show an ordinary two-word name in full.
        XCTAssertGreaterThanOrEqual(ConversationHeaderLayoutPolicy.maximumNameWidth, 150)
    }

    func testMarqueeOnlyScrollsTextThatDoesNotFit() {
        XCTAssertFalse(
            MarqueeTextPolicy.scrolls(containerWidth: 82, textWidth: 60, reduceMotion: false)
        )
        XCTAssertFalse(
            MarqueeTextPolicy.scrolls(containerWidth: 82, textWidth: 82, reduceMotion: false)
        )
        XCTAssertTrue(
            MarqueeTextPolicy.scrolls(containerWidth: 82, textWidth: 140, reduceMotion: false)
        )
        // Reduce Motion never scrolls; the label truncates instead.
        XCTAssertFalse(
            MarqueeTextPolicy.scrolls(containerWidth: 82, textWidth: 140, reduceMotion: true)
        )
        // Before the first layout pass there is nothing to compare against.
        XCTAssertFalse(
            MarqueeTextPolicy.scrolls(containerWidth: 0, textWidth: 140, reduceMotion: false)
        )
    }

    func testMarqueeRestDurationPreservesTheRequestedCycleFraction() {
        let rest = 0.22
        let movement = 10.0
        let pause = MarqueeTextPolicy.restDuration(
            movementDuration: movement,
            restFraction: rest
        )
        XCTAssertEqual(pause / (pause + movement), rest, accuracy: 0.0001)
        XCTAssertEqual(
            MarqueeTextPolicy.restDuration(movementDuration: movement, restFraction: -1),
            0,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            MarqueeTextPolicy.restDuration(movementDuration: movement, restFraction: 4),
            movement
        )
    }

    func testMarqueeCycleNeverRunsTooFastToRead() {
        XCTAssertEqual(
            MarqueeTextPolicy.cycleDuration(distance: 240, pointsPerSecond: 24),
            10,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(
            MarqueeTextPolicy.cycleDuration(distance: 1, pointsPerSecond: 24),
            0.6
        )
        XCTAssertGreaterThanOrEqual(
            MarqueeTextPolicy.cycleDuration(distance: 240, pointsPerSecond: 0),
            0.6
        )
    }

    func testPhotoBubbleBorderIsThinAndOmitsBottomEdge() {
        XCTAssertEqual(
            SecurePhotoBubbleBorderPolicy.edges,
            [.left, .right, .top]
        )
        XCTAssertFalse(SecurePhotoBubbleBorderPolicy.edges.contains(.bottom))
        XCTAssertGreaterThan(SecurePhotoBubbleBorderPolicy.lineWidth, 0)
        XCTAssertLessThanOrEqual(SecurePhotoBubbleBorderPolicy.lineWidth, 0.5)
    }
}

@MainActor
private final class MessageNotificationActionProbe {
    var actions: [MessageNotificationAction] = []
    var conversationAvailable = false
    var syncAttempts = 0
}

@MainActor
private final class FakeVisibleMessageNotificationCenter: VisibleMessageNotificationCenter {
    let authorizationSnapshot: VisibleMessageNotificationAuthorization
    private(set) var activeRecords: [VisibleMessageNotificationRecord]
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedPendingIdentifiers: [String] = []
    private(set) var removedDeliveredIdentifiers: [String] = []
    private var shouldSuspendNextActiveLookup = false
    private var activeLookupContinuation:
        CheckedContinuation<[VisibleMessageNotificationRecord], Never>?
    private var activeLookupWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        authorization: VisibleMessageNotificationAuthorization,
        activeRecords: [VisibleMessageNotificationRecord] = []
    ) {
        authorizationSnapshot = authorization
        self.activeRecords = activeRecords
    }

    func authorization() async -> VisibleMessageNotificationAuthorization {
        authorizationSnapshot
    }

    func activeMessageNotifications() async -> [VisibleMessageNotificationRecord] {
        guard shouldSuspendNextActiveLookup else { return activeRecords }
        shouldSuspendNextActiveLookup = false
        return await withCheckedContinuation { continuation in
            activeLookupContinuation = continuation
            let waiters = activeLookupWaiters
            activeLookupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func suspendNextActiveLookup() {
        shouldSuspendNextActiveLookup = true
    }

    func waitForSuspendedActiveLookup() async {
        if activeLookupContinuation != nil { return }
        await withCheckedContinuation { continuation in
            activeLookupWaiters.append(continuation)
        }
    }

    func resumeSuspendedActiveLookup() {
        let records = activeRecords
        let continuation = activeLookupContinuation
        activeLookupContinuation = nil
        continuation?.resume(returning: records)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
        let identifiers = Set(identifiers)
        activeRecords.removeAll {
            $0.location == .pending && identifiers.contains($0.requestIdentifier)
        }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
        let identifiers = Set(identifiers)
        activeRecords.removeAll {
            $0.location == .delivered && identifiers.contains($0.requestIdentifier)
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        activeRecords.removeAll {
            $0.location == .pending && $0.requestIdentifier == request.identifier
        }
        let content = request.content
        activeRecords.append(VisibleMessageNotificationRecord(
            requestIdentifier: request.identifier,
            threadIdentifier: content.threadIdentifier,
            conversationID: content.userInfo["conversation_id"] as! String,
            accountFingerprint: content.userInfo["account_fingerprint"] as! String,
            version: MessageNotificationVersion(
                messageDigest: content.userInfo["message_digest"] as! String,
                sentAtEpochSecond: content.userInfo["sent_at_epoch_second"] as! Int64,
                sentAtNanosecond: content.userInfo["sent_at_nanosecond"] as! Int
            ),
            location: .pending,
            deliveredAt: nil
        ))
    }
}
