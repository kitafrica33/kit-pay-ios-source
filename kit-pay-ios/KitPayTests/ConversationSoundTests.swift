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
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher()
        let probe = MessageNotificationActionProbe()

        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)
        await dispatcher.install { received in
            probe.actions.append(received)
            return true
        }
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [action])
    }

    @MainActor
    func testMessageNotificationDispatcherRetriesOnlyAnUncompletedResponse() async throws {
        let descriptor = try XCTUnwrap(notificationDescriptor())
        let action = try XCTUnwrap(notificationAction(
            descriptor,
            userInfo: notificationUserInfo(descriptor)
        ))
        let dispatcher = MessageNotificationActionDispatcher()
        let probe = MessageNotificationActionProbe()
        await dispatcher.install { received in
            probe.actions.append(received)
            return probe.actions.count > 1
        }

        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)
        await dispatcher.dispatch(action)

        XCTAssertEqual(probe.actions, [action, action])
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
