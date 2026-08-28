import Foundation
import ImageIO
import UIKit
import XCTest
@testable import KitPay

final class AccountSetupPolicyTests: XCTestCase {
    func testProfileMutationMergePreservesOmittedFieldsAndAppliesRequestedIdentity() throws {
        let current = UserProfile(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            name: "Old Name",
            email: "verified@example.test",
            phone: "+256750000002",
            countryCode: "UG",
            tag: "old-tag",
            avatarURL: "https://pay.kit.africa/avatar.jpg",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: true,
            emailVerified: true,
            phoneVerified: true,
            profileSetupRequired: true
        )
        let focused = UserProfile(
            id: current.id,
            name: nil,
            email: nil,
            phone: nil,
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: nil
        )
        let merged = try XCTUnwrap(UserProfileMutationMergePolicy.merge(
            response: focused,
            current: current,
            requestedName: "New Name",
            requestedTag: "new-tag"
        ))

        XCTAssertEqual(merged.name, "New Name")
        XCTAssertEqual(merged.tag, "new-tag")
        XCTAssertEqual(merged.email, current.email)
        XCTAssertEqual(merged.phone, current.phone)
        XCTAssertEqual(merged.avatarURL, current.avatarURL)
        XCTAssertEqual(merged.kycStatus, current.kycStatus)
        XCTAssertEqual(merged.paymentPinSet, true)
        XCTAssertEqual(merged.mfaEnabled, true)
        XCTAssertEqual(merged.emailVerified, true)
        XCTAssertEqual(merged.phoneVerified, true)
        XCTAssertEqual(merged.profileSetupRequired, false)
    }

    func testProfileMutationMergeRejectsAResponseForAnotherAccount() {
        let current = emptyProfile(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let response = emptyProfile(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

        XCTAssertNil(UserProfileMutationMergePolicy.merge(response: response, current: current))
    }

    private func emptyProfile(id: String) -> UserProfile {
        UserProfile(
            id: id,
            name: nil,
            email: nil,
            phone: nil,
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: nil
        )
    }
    private actor AvatarDeadlineCancellationProbe {
        private(set) var observed = false

        func markObserved() {
            observed = true
        }
    }

    func testProfileAvatarCapabilityPrefersDedicatedFlagAndSupportsLegacyMedia() {
        let dedicated = CapabilitiesDTO(
            apiVersion: "v1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["media": false, "profile_avatars": true],
            authentication: nil
        )
        let explicitlyDisabled = CapabilitiesDTO(
            apiVersion: "v1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["media": true, "profile_avatars": false],
            authentication: nil
        )
        let legacy = CapabilitiesDTO(
            apiVersion: "v1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["media": true],
            authentication: nil
        )
        let unavailable = CapabilitiesDTO(
            apiVersion: "v1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["media": false],
            authentication: nil
        )

        XCTAssertTrue(dedicated.enablesProfileAvatars)
        XCTAssertFalse(explicitlyDisabled.enablesProfileAvatars)
        XCTAssertTrue(legacy.enablesProfileAvatars)
        XCTAssertFalse(unavailable.enablesProfileAvatars)
    }

    func testProfileProjectionDecodesAvatarAndRemainsBackwardCompatible() throws {
        let current = try JSONDecoder().decode(UserProfile.self, from: Data(#"""
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "name": "Amina Yusuf",
          "avatar_url": "https://pay.kit.africa/profiles/11111111-1111-4111-8111-111111111111/avatar/22222222-2222-4222-8222-222222222222"
        }
        """#.utf8))
        let legacy = try JSONDecoder().decode(UserProfile.self, from: Data(#"""
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "name": "Amina Yusuf"
        }
        """#.utf8))

        XCTAssertEqual(
            current.avatarURL,
            "https://pay.kit.africa/profiles/11111111-1111-4111-8111-111111111111/avatar/22222222-2222-4222-8222-222222222222"
        )
        XCTAssertNil(legacy.avatarURL)
    }

    func testProfileAvatarPreparationIsSquareStripsSensitiveMetadataAndIsSmall() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image {
            $0.cgContext.setFillColor(UIColor.systemGreen.cgColor)
            $0.cgContext.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            $0.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            $0.cgContext.fill(CGRect(x: 600, y: 0, width: 600, height: 600))
        }
        let sourceImage = try XCTUnwrap(source.cgImage)
        let taggedInput = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                taggedInput as CFMutableData,
                "public.jpeg" as CFString,
                1,
                nil
            )
        )
        let sensitiveMetadata: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "private-avatar-note",
                kCGImagePropertyExifDateTimeOriginal: "2026:08:19 08:00:00",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 0.3476,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 32.5825,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Private Camera Make",
                kCGImagePropertyTIFFModel: "Private Camera Model",
            ],
        ]
        CGImageDestinationAddImage(destination, sourceImage, sensitiveMetadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let input = taggedInput as Data
        let taggedSource = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let taggedProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(taggedSource, 0, nil) as? [CFString: Any]
        )
        let taggedExif = try XCTUnwrap(
            taggedProperties[kCGImagePropertyExifDictionary] as? NSDictionary
        )
        let taggedTIFF = try XCTUnwrap(
            taggedProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        )
        XCTAssertNotNil(taggedExif.object(forKey: kCGImagePropertyExifUserComment))
        XCTAssertNotNil(taggedExif.object(forKey: kCGImagePropertyExifDateTimeOriginal))
        let taggedGPS = try XCTUnwrap(
            taggedProperties[kCGImagePropertyGPSDictionary] as? NSDictionary
        )
        XCTAssertNotNil(taggedGPS.object(forKey: kCGImagePropertyGPSLatitude))
        XCTAssertNotNil(taggedGPS.object(forKey: kCGImagePropertyGPSLongitude))
        XCTAssertEqual(
            taggedTIFF.object(forKey: kCGImagePropertyTIFFMake) as? String,
            "Private Camera Make"
        )
        XCTAssertEqual(
            taggedTIFF.object(forKey: kCGImagePropertyTIFFModel) as? String,
            "Private Camera Model"
        )

        let output = try XCTUnwrap(ProfileAvatarImagePreparer.prepareJPEG(from: input))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary

        XCTAssertLessThanOrEqual(output.count, ProfileAvatarUploadPolicy.maximumBytes)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 512)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 512)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(exif?.object(forKey: kCGImagePropertyExifUserComment))
        XCTAssertNil(exif?.object(forKey: kCGImagePropertyExifDateTimeOriginal))
        XCTAssertNil(tiff?.object(forKey: kCGImagePropertyTIFFMake))
        XCTAssertNil(tiff?.object(forKey: kCGImagePropertyTIFFModel))
    }

    func testProfileAvatarMediaIntentResponseDecodesStrictContract() throws {
        let response = try JSONDecoder().decode(MediaUploadIntentDTO.self, from: Data(#"""
        {
          "asset": {
            "id": "22222222-2222-4222-8222-222222222222",
            "status": "pending_upload",
            "scan": {"status": "pending"}
          },
          "upload": {
            "method": "PUT",
            "url": "https://objects.example.test/upload?signature=opaque",
            "headers": {
              "Content-Type": "image/jpeg",
              "Content-Length": "12345"
            },
            "expires_at": "2026-08-19T06:00:00Z"
          }
        }
        """#.utf8))

        XCTAssertEqual(response.asset.status, "pending_upload")
        XCTAssertEqual(response.asset.scan.status, "pending")
        XCTAssertEqual(response.upload.method, "PUT")
        XCTAssertEqual(response.upload.headers["Content-Type"], "image/jpeg")
    }

    func testGroupPhotoUploadUsesPersistedSessionWhenNoTaskLocalSessionExists() {
        XCTAssertEqual(
            AuthenticatedMediaUploadSessionPolicy.sessionID(
                inherited: nil,
                persisted: "signed-in-session"
            ),
            "signed-in-session"
        )
        XCTAssertEqual(
            AuthenticatedMediaUploadSessionPolicy.sessionID(
                inherited: "operation-session",
                persisted: "stale-session"
            ),
            "operation-session"
        )
        XCTAssertNil(AuthenticatedMediaUploadSessionPolicy.sessionID(
            inherited: nil,
            persisted: nil
        ))
    }

    func testProfileAvatarScanPollingIsBoundedToNinetySeconds() {
        XCTAssertEqual(ProfileAvatarUploadPolicy.maximumScanWaitSeconds, 90)
        XCTAssertEqual(ProfileAvatarUploadPolicy.maximumScanWait, .seconds(90))
        XCTAssertEqual(ProfileAvatarUploadPolicy.scanPollIntervalSeconds, 3)
        XCTAssertEqual(ProfileAvatarUploadPolicy.maximumScanPolls, 31)
        XCTAssertEqual(
            (ProfileAvatarUploadPolicy.maximumScanPolls - 1)
                * ProfileAvatarUploadPolicy.scanPollIntervalSeconds,
            ProfileAvatarUploadPolicy.maximumScanWaitSeconds
        )
        XCTAssertEqual(
            ProfileAvatarUploadPolicy.scanPollNanoseconds,
            UInt64(ProfileAvatarUploadPolicy.scanPollIntervalSeconds) * 1_000_000_000
        )
        XCTAssertLessThanOrEqual(ProfileAvatarUploadPolicy.maximumScanPolls, 31)
    }

    func testProfileAvatarDeadlineReturnsPromptSuccess() async throws {
        let value = try await ProfileAvatarDeadline.run(maximumWait: .seconds(1)) {
            "ready"
        }

        XCTAssertEqual(value, "ready")
    }

    func testProfileAvatarDeadlineCancelsSlowTransport() async {
        let probe = AvatarDeadlineCancellationProbe()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            let _: String = try await ProfileAvatarDeadline.run(
                maximumWait: .milliseconds(20)
            ) {
                do {
                    try await Task.sleep(for: .seconds(5))
                    return "late"
                } catch is CancellationError {
                    await probe.markObserved()
                    throw CancellationError()
                }
            }
            XCTFail("Expected the profile avatar deadline to expire")
        } catch let error as ProfileAvatarUploadError {
            XCTAssertEqual(error, .scanTimedOut)
        } catch {
            XCTFail("Unexpected deadline error: \(error)")
        }

        let observedCancellation = await probe.observed
        XCTAssertTrue(observedCancellation)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testPendingProfileAvatarResumesOnlyForCapturedAccountAndSession() {
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        let pending = pendingAvatarAttachment(finalizedAt: now.addingTimeInterval(-30))

        XCTAssertTrue(ProfileAvatarPendingAttachmentPolicy.isResumable(
            pending,
            userID: pending.ownerUserID,
            sessionID: pending.sessionID,
            now: now
        ))
        XCTAssertFalse(ProfileAvatarPendingAttachmentPolicy.isResumable(
            pending,
            userID: "22222222-2222-4222-8222-222222222222",
            sessionID: pending.sessionID,
            now: now
        ))
        XCTAssertFalse(ProfileAvatarPendingAttachmentPolicy.isResumable(
            pending,
            userID: pending.ownerUserID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            now: now
        ))
    }

    func testPendingProfileAvatarDigestReusesOnlyTheSamePreparedPhoto() {
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        let original = Data("original-photo".utf8)
        let replacement = Data("replacement-photo".utf8)
        let pending = pendingAvatarAttachment(
            sourceSHA256: ProfileAvatarUploadPolicy.sha256(of: original),
            finalizedAt: now
        )

        XCTAssertTrue(ProfileAvatarPendingAttachmentPolicy.represents(
            pending,
            jpegData: original,
            userID: pending.ownerUserID,
            sessionID: pending.sessionID,
            now: now
        ))
        XCTAssertFalse(ProfileAvatarPendingAttachmentPolicy.represents(
            pending,
            jpegData: replacement,
            userID: pending.ownerUserID,
            sessionID: pending.sessionID,
            now: now
        ))
    }

    func testDifferentAvatarSelectionDiscardsPendingBeforeProfilePatchCanFail() {
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        let original = Data("original-photo".utf8)
        let replacement = Data("replacement-photo".utf8)
        let pending = pendingAvatarAttachment(
            sourceSHA256: ProfileAvatarUploadPolicy.sha256(of: original),
            finalizedAt: now
        )

        XCTAssertEqual(
            ProfileAvatarPendingAttachmentPolicy.selectionDisposition(
                for: pending,
                jpegData: original,
                userID: pending.ownerUserID,
                sessionID: pending.sessionID,
                now: now
            ),
            .resumeExisting
        )
        XCTAssertEqual(
            ProfileAvatarPendingAttachmentPolicy.selectionDisposition(
                for: pending,
                jpegData: replacement,
                userID: pending.ownerUserID,
                sessionID: pending.sessionID,
                now: now
            ),
            .discardBeforeProfileUpdate
        )
    }

    func testPendingProfileAvatarRejectsMalformedAndExpiredRecords() {
        let now = Date(timeIntervalSince1970: 1_776_000_000)
        let valid = pendingAvatarAttachment(finalizedAt: now)

        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(assetID: "not-an-asset-id", finalizedAt: now),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(assetID: " \(valid.assetID)", finalizedAt: now),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(ownerUserID: "", finalizedAt: now),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(sourceSHA256: String(repeating: "a", count: 63), finalizedAt: now),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(sourceSHA256: String(repeating: "A", count: 64), finalizedAt: now),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(
                finalizedAt: now.addingTimeInterval(
                    -ProfileAvatarPendingAttachmentPolicy.maximumRetentionSeconds - 1
                )
            ),
            now: now
        ))
        XCTAssertFalse(isResumableAvatar(
            pendingAvatarAttachment(finalizedAt: now.addingTimeInterval(5 * 60 + 1)),
            now: now
        ))
        XCTAssertTrue(isResumableAvatar(
            pendingAvatarAttachment(
                finalizedAt: now.addingTimeInterval(
                    -ProfileAvatarPendingAttachmentPolicy.maximumRetentionSeconds
                )
            ),
            now: now
        ))
        XCTAssertTrue(isResumableAvatar(
            pendingAvatarAttachment(finalizedAt: now.addingTimeInterval(5 * 60)),
            now: now
        ))
    }

    func testPendingProfileAvatarRetainsTransientFailuresAndDiscardsTerminalFailures() {
        let retainedErrors: [Error] = [
            ProfileAvatarUploadError.scanTimedOut,
            ProfileAvatarUploadError.invalidServiceResponse,
            APIClientError.httpStatus(503),
            APIClientError.httpResponse(status: 429, retryAfter: 2),
            APIErrorPayload(code: "RATE_LIMITED", message: "Retry later"),
            URLError(.timedOut),
        ]
        let discardedErrors: [Error] = [
            ProfileAvatarUploadError.rejected,
            ProfileAvatarUploadError.invalidImage,
            APIErrorPayload(code: "MEDIA_NOT_FOUND", message: "Missing"),
            APIErrorPayload(code: "PROFILE_AVATAR_INVALID", message: "Invalid"),
            APIErrorPayload(code: "UNKNOWN", message: "Gone", httpStatus: 404),
            APIClientError.httpStatus(404),
            APIClientError.httpResponse(status: 410, retryAfter: nil),
            APIClientError.httpResponse(status: 422, retryAfter: nil),
        ]

        retainedErrors.forEach {
            XCTAssertFalse(
                ProfileAvatarPendingAttachmentPolicy.shouldDiscard(after: $0),
                "Unexpectedly discarded transient error: \($0)"
            )
        }
        discardedErrors.forEach {
            XCTAssertTrue(
                ProfileAvatarPendingAttachmentPolicy.shouldDiscard(after: $0),
                "Unexpectedly retained terminal error: \($0)"
            )
        }
    }

    func testAPIClientSessionBindingIsTaskLocalAndRestoresOuterScope() async {
        let outerSession = "44444444-4444-4444-8444-444444444444"
        let innerSession = "55555555-5555-4555-8555-555555555555"

        XCTAssertNil(APIClientSessionBinding.sessionID)
        let observations = await APIClientSessionBinding.$sessionID.withValue(outerSession) {
            let initial = APIClientSessionBinding.sessionID
            let inheritedByChild = await Task {
                APIClientSessionBinding.sessionID
            }.value
            let nested = await APIClientSessionBinding.$sessionID.withValue(innerSession) {
                await Task.yield()
                return APIClientSessionBinding.sessionID
            }
            let restored = APIClientSessionBinding.sessionID
            let inheritedByGroup = await withTaskGroup(of: String?.self) { group -> String? in
                group.addTask { APIClientSessionBinding.sessionID }
                return await group.next() ?? nil
            }
            let detached = await Task.detached {
                APIClientSessionBinding.sessionID
            }.value
            return (initial, inheritedByChild, nested, restored, inheritedByGroup, detached)
        }

        XCTAssertEqual(observations.0, outerSession)
        XCTAssertEqual(observations.1, outerSession)
        XCTAssertEqual(observations.2, innerSession)
        XCTAssertEqual(observations.3, outerSession)
        XCTAssertEqual(observations.4, outerSession)
        XCTAssertNil(observations.5)
        XCTAssertNil(APIClientSessionBinding.sessionID)
    }

    func testNewAccountRoutesProfileThenDeviceVerificationThenPin() {
        let user = profile(
            name: "Kit Pay User",
            tag: "kit_a1b2c3d4e5",
            paymentPinSet: false,
            profileSetupRequired: false
        )

        let first = AccountSetupPolicy.initialStep(afterAuthentication: user)

        XCTAssertEqual(first, .profile(needsPaymentPin: true))
        XCTAssertEqual(
            AccountSetupPolicy.nextStep(afterCompleting: first!),
            .deviceVerification(needsPaymentPin: true)
        )
        XCTAssertEqual(
            AccountSetupPolicy.nextStep(
                afterCompleting: .deviceVerification(needsPaymentPin: true)
            ),
            .paymentPin
        )
    }

    func testMissingAuthenticatedUserFailsClosed() {
        XCTAssertEqual(
            AccountSetupPolicy.initialStep(afterAuthentication: nil),
            .profile(needsPaymentPin: true)
        )
        XCTAssertEqual(
            AccountSetupPolicy.restoredStep(user: nil),
            .profile(needsPaymentPin: true)
        )
    }

    func testServerFalseCannotBypassMalformedOrReservedIdentity() {
        XCTAssertTrue(AccountSetupPolicy.requiresProfileSetup(profile(
            name: "Amina",
            tag: "support",
            paymentPinSet: true,
            profileSetupRequired: false
        )))
        XCTAssertTrue(AccountSetupPolicy.requiresProfileSetup(profile(
            name: "Amina",
            tag: "bad-tag",
            paymentPinSet: true,
            profileSetupRequired: false
        )))
    }

    func testMissingAssuranceFailsClosedAtDeviceVerification() {
        XCTAssertEqual(
            AccountSetupPolicy.initialStep(afterAuthentication: profile(
                name: "Amina Yusuf",
                tag: "amina_01",
                paymentPinSet: nil,
                profileSetupRequired: nil
            )),
            .deviceVerification(needsPaymentPin: true)
        )
    }

    func testVerifiedDeviceRoutesNewAccountToPinSetup() {
        XCTAssertEqual(
            AccountSetupPolicy.initialStep(
                afterAuthentication: profile(
                    name: "Amina Yusuf",
                    tag: "amina_01",
                    paymentPinSet: false,
                    profileSetupRequired: false
                ),
                assurance: assurance(deviceStatus: "verified", unlockStatus: "locked")
            ),
            .paymentPin
        )
    }

    func testOptionalDeviceVerificationStillRequiresReturningLoginUnlock() {
        let returning = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: true,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.initialStep(
                afterAuthentication: returning,
                assurance: assurance(
                    deviceStatus: "not_required",
                    unlockStatus: "locked",
                    deviceRequired: false
                )
            ),
            .loginUnlock
        )
        XCTAssertNil(AccountSetupPolicy.initialStep(
            afterAuthentication: returning,
            assurance: assurance(
                deviceStatus: "not_required",
                unlockStatus: "unlocked",
                deviceRequired: false
            )
        ))
    }

    func testOptionalDeviceVerificationStillRequiresFirstPaymentPinSetup() {
        let newAccount = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: false,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.initialStep(
                afterAuthentication: newAccount,
                assurance: assurance(
                    deviceStatus: "not_required",
                    unlockStatus: "locked",
                    deviceRequired: false
                )
            ),
            .paymentPin
        )
    }

    func testRequiredDeviceVerificationCannotBeSkippedByLoginUnlock() {
        let returning = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: true,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.initialStep(
                afterAuthentication: returning,
                assurance: assurance(deviceStatus: "required", unlockStatus: "locked")
            ),
            .deviceVerification(needsPaymentPin: false)
        )
    }

    func testReturningLoginRequiresUnlockAfterFreshDeviceVerification() {
        let returning = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: true,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.initialStep(
                afterAuthentication: returning,
                assurance: assurance(deviceStatus: "verified", unlockStatus: "locked")
            ),
            .loginUnlock
        )
        XCTAssertNil(AccountSetupPolicy.initialStep(
            afterAuthentication: returning,
            assurance: assurance(deviceStatus: "verified", unlockStatus: "unlocked")
        ))
    }

    func testReconciliationRetainsCarriedPinRequirement() {
        let complete = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: false,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.reconcile(
                .deviceVerification(needsPaymentPin: true),
                with: complete,
                assurance: assurance(deviceStatus: "verified", unlockStatus: "locked")
            ),
            .paymentPin
        )
        XCTAssertEqual(
            AccountSetupPolicy.reconcile(
                .profile(needsPaymentPin: false),
                with: complete,
                assurance: assurance(deviceStatus: "required", unlockStatus: "locked")
            ),
            .deviceVerification(needsPaymentPin: true)
        )

        let returning = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: true,
            profileSetupRequired: false
        )
        XCTAssertEqual(
            AccountSetupPolicy.reconcile(
                .deviceVerification(needsPaymentPin: false),
                with: returning,
                assurance: assurance(deviceStatus: "verified", unlockStatus: "locked")
            ),
            .loginUnlock
        )

        let incomplete = profile(
            name: "Kit Pay User",
            tag: nil,
            paymentPinSet: false,
            profileSetupRequired: true
        )
        XCTAssertEqual(
            AccountSetupPolicy.reconcile(
                .paymentPin,
                with: incomplete,
                assurance: assurance(deviceStatus: "verified", unlockStatus: "locked")
            ),
            .profile(needsPaymentPin: true)
        )
    }

    func testBootstrapAccessFlagAlsoFailsClosed() {
        let returning = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: true,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.restoredStep(
                user: returning,
                assurance: assurance(
                    deviceStatus: "verified",
                    unlockStatus: "unlocked",
                    access: "restricted"
                )
            ),
            .loginUnlock
        )
    }

    func testNullablePinFlagStillRequiresPinAfterDeviceVerification() {
        let user = profile(
            name: "Amina Yusuf",
            tag: "amina_01",
            paymentPinSet: nil,
            profileSetupRequired: false
        )

        XCTAssertEqual(
            AccountSetupPolicy.restoredStep(
                user: user,
                assurance: assurance(deviceStatus: "verified", unlockStatus: "unlocked")
            ),
            .paymentPin
        )
    }

    func testProfileAndPinRequestsMatchAndroidWireContract() throws {
        let profileData = try JSONEncoder().encode(UpdateProfileRequest(name: "Amina", tag: "amina_01"))
        let profileObject = try XCTUnwrap(JSONSerialization.jsonObject(with: profileData) as? [String: Any])
        XCTAssertEqual(profileObject["name"] as? String, "Amina")
        XCTAssertEqual(profileObject["tag"] as? String, "amina_01")

        let pinData = try JSONEncoder().encode(SetPaymentPinRequest(pin: "2580"))
        let pinObject = try XCTUnwrap(JSONSerialization.jsonObject(with: pinData) as? [String: Any])
        XCTAssertEqual(pinObject["pin"] as? String, "2580")
        XCTAssertEqual(pinObject["pin_confirmation"] as? String, "2580")
        XCTAssertFalse(pinObject.keys.contains("current_pin"))
    }

    func testSecurityPreferencesAPIAndPatchWireContract() throws {
        XCTAssertEqual(SecurityPreferencesAPIEndpoint.read.path, "auth/security-preferences")
        XCTAssertEqual(SecurityPreferencesAPIEndpoint.read.method, "GET")
        XCTAssertEqual(SecurityPreferencesAPIEndpoint.update.path, "auth/security-preferences")
        XCTAssertEqual(SecurityPreferencesAPIEndpoint.update.method, "PATCH")

        let request = try UpdateSecurityPreferencesRequest(
            version: 7,
            verifyIdentityOnNewLogin: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set(["version", "verify_identity_on_new_login"])
        )
        XCTAssertEqual(object["version"] as? Int, 7)
        XCTAssertEqual(object["verify_identity_on_new_login"] as? Bool, true)
        XCTAssertThrowsError(
            try UpdateSecurityPreferencesRequest(
                version: 0,
                verifyIdentityOnNewLogin: false
            )
        )
    }

    func testSecurityPreferencesResponseIsStrictAndSupportsDefaultTimestamp() throws {
        let initial = try securityPreferences(
            version: 1,
            verifyIdentityOnNewLogin: false,
            updatedAt: nil
        )
        XCTAssertEqual(initial.version, 1)
        XCTAssertFalse(initial.verifyIdentityOnNewLogin)
        XCTAssertNil(initial.updatedAt)

        let updated = try securityPreferences(
            version: 2,
            verifyIdentityOnNewLogin: true,
            updatedAt: "2026-08-21T03:00:00Z"
        )
        XCTAssertEqual(updated.version, 2)
        XCTAssertTrue(updated.verifyIdentityOnNewLogin)

        XCTAssertThrowsError(try JSONDecoder().decode(
            SecurityPreferencesDTO.self,
            from: Data(#"""
            {
              "version": 1,
              "verify_identity_on_new_login": false,
              "updated_at": null,
              "unsupported": true
            }
            """#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SecurityPreferencesDTO.self,
            from: Data(#"""
            {
              "version": 1,
              "verify_identity_on_new_login": false
            }
            """#.utf8)
        ))
    }

    func testSecurityPreferenceTransitionRequiresExactEchoAndVersion() throws {
        let initial = try securityPreferences(
            version: 1,
            verifyIdentityOnNewLogin: false,
            updatedAt: nil
        )
        let enabled = try securityPreferences(
            version: 2,
            verifyIdentityOnNewLogin: true,
            updatedAt: "2026-08-21T03:00:00Z"
        )
        let wrongVersion = try securityPreferences(
            version: 3,
            verifyIdentityOnNewLogin: true,
            updatedAt: "2026-08-21T03:00:00Z"
        )
        let wrongValue = try securityPreferences(
            version: 2,
            verifyIdentityOnNewLogin: false,
            updatedAt: "2026-08-21T03:00:00Z"
        )

        XCTAssertTrue(SecurityPreferencesUpdatePolicy.isValidTransition(
            from: initial,
            to: enabled,
            requestedValue: true
        ))
        XCTAssertFalse(SecurityPreferencesUpdatePolicy.isValidTransition(
            from: initial,
            to: wrongVersion,
            requestedValue: true
        ))
        XCTAssertFalse(SecurityPreferencesUpdatePolicy.isValidTransition(
            from: initial,
            to: wrongValue,
            requestedValue: true
        ))
        XCTAssertTrue(SecurityPreferencesUpdatePolicy.isValidTransition(
            from: initial,
            to: initial,
            requestedValue: false
        ))
    }

    func testSessionAssuranceWireContractDecodesStrictly() throws {
        let json = Data(#"""
        {
          "session_assurance": {
            "device_identity": {
              "status": "verified",
              "required": false,
              "epoch": 4,
              "verified_at": "2026-08-18T12:00:00Z"
            },
            "login_unlock": {
              "status": "locked",
              "required": true,
              "method": null,
              "methods": ["pin", "biometric_signature"],
              "unlocked_at": null
            },
            "access": "restricted"
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(SessionAssuranceResponseDTO.self, from: json)

        XCTAssertTrue(response.sessionAssurance.deviceIdentity.isVerified)
        XCTAssertFalse(response.sessionAssurance.loginUnlock.isUnlocked)
        XCTAssertTrue(response.sessionAssurance.loginUnlock.supportsBiometricSignature)
        XCTAssertFalse(response.sessionAssurance.grantsFullAccess)
    }

    func testBiometricEnrollmentResponseCarriesUpdatedSessionAssurance() throws {
        let json = Data(#"""
        {
          "device_id": "device-1",
          "algorithm": "ES256",
          "enrolled_at": "2026-08-19T12:00:00Z",
          "attestation_status": "registered_unverified",
          "session_assurance": {
            "device_identity": {
              "status": "verified",
              "required": false,
              "epoch": 4,
              "verified_at": "2026-08-19T11:00:00Z"
            },
            "login_unlock": {
              "status": "unlocked",
              "required": false,
              "method": "pin",
              "methods": ["pin", "biometric_signature"],
              "unlocked_at": "2026-08-19T11:05:00Z"
            },
            "access": "full"
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(BiometricKeyStatusDTO.self, from: json)

        XCTAssertEqual(response.algorithm, "ES256")
        XCTAssertTrue(response.sessionAssurance?.grantsFullAccess == true)
        XCTAssertTrue(
            response.sessionAssurance?.loginUnlock.supportsBiometricSignature == true
        )
    }

    func testKYCStatusCarriesCurrentSessionDeviceVerification() throws {
        let json = Data(#"""
        {
          "status": "verified",
          "case": null,
          "provider_session": null,
          "documents": [],
          "device_verification": {
            "status": "pending",
            "required": true,
            "epoch": 2,
            "verified_at": null
          }
        }
        """#.utf8)

        let status = try JSONDecoder().decode(KYCStatus.self, from: json)

        XCTAssertEqual(status.status, "verified")
        XCTAssertEqual(status.deviceVerification?.status, "pending")
        XCTAssertFalse(status.deviceVerification?.isVerified ?? true)
    }

    func testNormalizationAndValidationMatchAndroid() {
        XCTAssertEqual(normalizeProfileName("  Amina\n\tYusuf  "), "Amina Yusuf")
        XCTAssertEqual(normalizeProfileTag("\u{00a0}@Amina_01\u{3000}"), "amina_01")
        XCTAssertNil(profileIdentityValidationError(name: "😀😀", tag: "emoji_name"))
        XCTAssertEqual(
            profileIdentityValidationError(name: "Amina", tag: "deleted_user"),
            "This username is reserved."
        )
        XCTAssertFalse(isValidPaymentPin("１２３４"))
        XCTAssertTrue(isValidPaymentPin("2580"))
    }

    func testVerifiedLegalNameMakesTheDisplayNameOptional() {
        // Nothing typed: the verified identity already names the account.
        XCTAssertNil(
            profileIdentityValidationError(
                name: "",
                tag: "amina_01",
                verifiedLegalName: "Amina Yusuf"
            )
        )
        // The server's placeholder counts as "not chosen", not as a bad entry.
        XCTAssertNil(
            profileIdentityValidationError(
                name: "Kit Pay User",
                tag: "amina_01",
                verifiedLegalName: "Amina Yusuf"
            )
        )
        // Anything actually typed is still validated.
        XCTAssertEqual(
            profileIdentityValidationError(
                name: "A",
                tag: "amina_01",
                verifiedLegalName: "Amina Yusuf"
            ),
            "Enter a display name (2–120 characters)."
        )
        // Without a verified legal name the display name stays mandatory.
        XCTAssertEqual(
            profileIdentityValidationError(name: "", tag: "amina_01"),
            "Enter a display name (2–120 characters)."
        )
    }

    func testOptionalUsernameAcceptsAnUnsetOrProvisionalTag() {
        XCTAssertNil(
            profileIdentityValidationError(
                name: "Amina Yusuf",
                tag: nil,
                usernameRequired: false
            )
        )
        XCTAssertNil(
            profileIdentityValidationError(
                name: "Amina Yusuf",
                tag: "kit_ab12cd34ef",
                usernameRequired: false
            )
        )
        // A username the user did choose must still be usable.
        XCTAssertEqual(
            profileIdentityValidationError(
                name: "Amina Yusuf",
                tag: "no",
                usernameRequired: false
            ),
            "Your username must be 3 to 32 characters."
        )
        // Default behaviour is unchanged for servers that predate the split.
        XCTAssertEqual(
            profileIdentityValidationError(name: "Amina Yusuf", tag: "kit_ab12cd34ef"),
            "Choose your own username."
        )
    }

    func testRequiresProfileSetupHonoursTheVerifiedLegalNameAndOptionalUsername() {
        var verified = UserProfile(id: "u-1", name: "Kit Pay User", tag: "kit_ab12cd34ef")
        verified.profileSetupRequired = false
        verified.legalName = "Amina Yusuf"
        verified.legalNameVerifiedAt = "2026-08-25T10:00:00Z"
        verified.usernameRequired = false
        XCTAssertFalse(AccountSetupPolicy.requiresProfileSetup(verified))

        // A server that still requires a username keeps the old gate.
        var requiresUsername = verified
        requiresUsername.usernameRequired = true
        XCTAssertTrue(AccountSetupPolicy.requiresProfileSetup(requiresUsername))

        // A server that predates the split omits the flag entirely; fail closed to the old rule.
        var legacy = verified
        legacy.usernameRequired = nil
        XCTAssertTrue(AccountSetupPolicy.requiresProfileSetup(legacy))

        // The server's own instruction still wins outright.
        var serverDemandsSetup = verified
        serverDemandsSetup.profileSetupRequired = true
        XCTAssertTrue(AccountSetupPolicy.requiresProfileSetup(serverDemandsSetup))
    }

    func testKYCVerificationURLPolicyAcceptsOnlyTheDiditHTTPSBoundary() {
        XCTAssertEqual(
            KYCVerificationURLPolicy.validatedURL(
                from: "https://verify.didit.me/session/valid-token"
            )?.host,
            "verify.didit.me"
        )
        XCTAssertNotNil(
            KYCVerificationURLPolicy.validatedURL(
                from: "https://verify.didit.me:443/session/valid-token"
            )
        )
        XCTAssertNil(
            KYCVerificationURLPolicy.validatedURL(
                from: "http://verify.didit.me/session/valid-token"
            )
        )
        XCTAssertNil(
            KYCVerificationURLPolicy.validatedURL(
                from: "https://verify.didit.me.evil.example/session/valid-token"
            )
        )
        XCTAssertNil(
            KYCVerificationURLPolicy.validatedURL(
                from: "https://user:password@verify.didit.me/session/valid-token"
            )
        )
    }

    func testKYCPollingStopsOnceTheDecisionIsIn() {
        for settled in ["verified", "approved", "rejected", "declined", "failed", "VERIFIED"] {
            XCTAssertTrue(KYCStatusPollingPolicy.isSettled(settled), settled)
            XCTAssertFalse(KYCStatusPollingPolicy.isAwaitingDecision(settled), settled)
            // Not even a customer who has just come back from the hosted check is polled once
            // the answer is already on the screen.
            XCTAssertFalse(
                KYCStatusPollingPolicy.shouldPoll(
                    status: settled,
                    returnedFromVerification: true,
                    isOnline: true
                ),
                settled
            )
        }
    }

    func testKYCPollingRunsWhileACaseIsUnderReview() {
        // The same status arrives spelled several ways depending on which service answered.
        for pending in ["pending", "in_review", "In Review", " REVIEWING ", "submitted", "processing"] {
            XCTAssertTrue(KYCStatusPollingPolicy.isAwaitingDecision(pending), pending)
            XCTAssertTrue(
                KYCStatusPollingPolicy.shouldPoll(
                    status: pending,
                    returnedFromVerification: false,
                    isOnline: true
                ),
                pending
            )
        }
    }

    func testKYCPollingWatchesForACaseAfterTheHostedCheckCloses() {
        // Coming back from Didit, the status has usually not moved off not_started yet: the case
        // is created server-side moments later. Waiting for it is the whole point of the poll.
        XCTAssertFalse(KYCStatusPollingPolicy.isAwaitingDecision("not_started"))
        XCTAssertTrue(
            KYCStatusPollingPolicy.shouldPoll(
                status: "not_started",
                returnedFromVerification: true,
                isOnline: true
            )
        )
        XCTAssertFalse(
            KYCStatusPollingPolicy.shouldPoll(
                status: "not_started",
                returnedFromVerification: false,
                isOnline: true
            )
        )
        XCTAssertFalse(
            KYCStatusPollingPolicy.shouldPoll(
                status: nil,
                returnedFromVerification: false,
                isOnline: true
            )
        )
        XCTAssertGreaterThan(KYCStatusPollingPolicy.graceAttemptsAfterVerification, 0)
    }

    func testKYCPollingNeverRunsOffline() {
        for status in ["pending", "not_started", "in_review"] {
            XCTAssertFalse(
                KYCStatusPollingPolicy.shouldPoll(
                    status: status,
                    returnedFromVerification: true,
                    isOnline: false
                ),
                status
            )
        }
    }

    func testKYCPollingBacksOffFromSecondsToHalfAMinute() {
        // The first check is quick because the decision often lands seconds after the check
        // closes; from there the interval grows so a screen left open all afternoon is not
        // hammering the server.
        XCTAssertEqual(KYCStatusPollingPolicy.interval(attempt: 0), 4, accuracy: 0.0001)
        XCTAssertEqual(KYCStatusPollingPolicy.interval(attempt: -1), 4, accuracy: 0.0001)
        var previous = KYCStatusPollingPolicy.interval(attempt: 0)
        for attempt in 1...5 {
            let interval = KYCStatusPollingPolicy.interval(attempt: attempt)
            XCTAssertGreaterThan(interval, previous, "attempt \(attempt)")
            XCTAssertLessThanOrEqual(interval, KYCStatusPollingPolicy.maximumInterval)
            previous = interval
        }
        XCTAssertEqual(
            KYCStatusPollingPolicy.interval(attempt: 40),
            KYCStatusPollingPolicy.maximumInterval,
            accuracy: 0.0001
        )
    }

    private func profile(
        name: String?,
        tag: String?,
        paymentPinSet: Bool?,
        profileSetupRequired: Bool?
    ) -> UserProfile {
        UserProfile(
            id: "user-1",
            name: name,
            email: nil,
            phone: "+256700000200",
            tag: tag,
            kycStatus: "not_started",
            paymentPinSet: paymentPinSet,
            mfaEnabled: nil,
            profileSetupRequired: profileSetupRequired
        )
    }

    private func pendingAvatarAttachment(
        assetID: String = "11111111-1111-4111-8111-111111111111",
        ownerUserID: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        sessionID: String = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        sourceSHA256: String = String(repeating: "a", count: 64),
        finalizedAt: Date
    ) -> PendingProfileAvatarAttachment {
        PendingProfileAvatarAttachment(
            assetID: assetID,
            ownerUserID: ownerUserID,
            sessionID: sessionID,
            sourceSHA256: sourceSHA256,
            finalizedAt: finalizedAt
        )
    }

    private func isResumableAvatar(
        _ pending: PendingProfileAvatarAttachment,
        now: Date
    ) -> Bool {
        ProfileAvatarPendingAttachmentPolicy.isResumable(
            pending,
            userID: pending.ownerUserID,
            sessionID: pending.sessionID,
            now: now
        )
    }

    private func assurance(
        deviceStatus: String,
        unlockStatus: String,
        access: String? = nil,
        deviceRequired: Bool = true
    ) -> SessionAssuranceDTO {
        let device = DeviceIdentityAssuranceDTO(
            status: deviceStatus,
            required: deviceRequired,
            epoch: 1,
            verifiedAt: deviceStatus == "verified" ? "2026-08-18T12:00:00Z" : nil
        )
        let unlock = LoginUnlockAssuranceDTO(
            status: unlockStatus,
            required: true,
            method: unlockStatus == "unlocked" ? "pin" : nil,
            methods: ["pin"],
            unlockedAt: unlockStatus == "unlocked" ? "2026-08-18T12:01:00Z" : nil
        )
        return SessionAssuranceDTO(
            deviceIdentity: device,
            loginUnlock: unlock,
            access: access ?? (
                device.isVerified && unlock.isUnlocked ? "full" : "restricted"
            )
        )
    }

    private func securityPreferences(
        version: Int,
        verifyIdentityOnNewLogin: Bool,
        updatedAt: String?
    ) throws -> SecurityPreferencesDTO {
        let timestamp = updatedAt.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(
            SecurityPreferencesDTO.self,
            from: Data("""
            {
              "version": \(version),
              "verify_identity_on_new_login": \(verifyIdentityOnNewLogin),
              "updated_at": \(timestamp)
            }
            """.utf8)
        )
    }
}


/// Home's first-run checklist derives every step from real state and disappears when done.
final class HomeStarterChecklistPolicyTests: XCTestCase {
    func testIdentityCompletesOnlyForAuthoritativeVerifiedStates() {
        XCTAssertTrue(HomeStarterChecklistPolicy.identityVerified(kycStatus: "verified"))
        XCTAssertTrue(HomeStarterChecklistPolicy.identityVerified(kycStatus: " Approved "))
        XCTAssertFalse(HomeStarterChecklistPolicy.identityVerified(kycStatus: "pending"))
        XCTAssertFalse(HomeStarterChecklistPolicy.identityVerified(kycStatus: "rejected"))
        XCTAssertFalse(HomeStarterChecklistPolicy.identityVerified(kycStatus: ""))
        // Fail closed: no loaded profile means not verified, never verified-by-default.
        XCTAssertFalse(HomeStarterChecklistPolicy.identityVerified(kycStatus: nil))
    }

    func testFirstMessageCountsOnlyGenuineSentOutboundUserMessages() throws {
        XCTAssertFalse(HomeStarterChecklistPolicy.hasSentFirstMessage(messages: []))
        // Inbound, failed, still-queued, empty, and event-descriptor bodies never count.
        XCTAssertFalse(HomeStarterChecklistPolicy.hasSentFirstMessage(messages: [
            message("hello there", isOutgoing: false, state: .received),
            message("failed send", isOutgoing: true, state: .failed),
            message("still queued", isOutgoing: true, state: .queued),
            message("   ", isOutgoing: true, state: .sent),
            message(KitPaymentMessage.prefix + "v=1", isOutgoing: true, state: .sent),
            message(KitGroupPaymentMessage.prefix + "v=1", isOutgoing: true, state: .sent),
            message(KitSystemMessage.prefix + "v=1", isOutgoing: true, state: .sent),
            message(KitMessageReaction.prefix + "v=1", isOutgoing: true, state: .sent),
            message(KitMessageEdit.prefix + "v=1", isOutgoing: true, state: .sent),
            // The shared policy catches reserved namespaces behind leading whitespace too.
            message("  " + KitPaymentMessage.prefix + "v=1", isOutgoing: true, state: .sent),
            message("\n\t" + KitSystemMessage.prefix + "v=1", isOutgoing: true, state: .sent),
        ]))
        XCTAssertTrue(HomeStarterChecklistPolicy.hasSentFirstMessage(messages: [
            message("hi!", isOutgoing: true, state: .sent),
        ]))
        XCTAssertTrue(HomeStarterChecklistPolicy.hasSentFirstMessage(messages: [
            message("delivered", isOutgoing: true, state: .delivered),
        ]))
        // A first photo is a first message: the media descriptor is user content.
        let firstPhoto = try KitMediaMessageDescriptor(
            attachmentID: "0a1b2c3d-0000-4000-8000-000000000001",
            storageKey: "0a1b2c3d-0000-4000-8000-000000000002",
            mediaType: "image/jpeg",
            ciphertextByteSize: 4_064,
            ciphertextSHA256: String(repeating: "ab", count: 32),
            keyMaterial: Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes),
            plaintextByteSize: 4_000,
            caption: nil
        ).encoded
        XCTAssertTrue(HomeStarterChecklistPolicy.hasSentFirstMessage(messages: [
            message(firstPhoto, isOutgoing: true, state: .sent),
        ]))
        // A demo conversation's rows are synthetic and complete nothing.
        XCTAssertFalse(HomeStarterChecklistPolicy.hasSentFirstMessage(
            messages: [message("hi!", isOutgoing: true, state: .sent)],
            isDemoConversation: { _ in true }
        ))
    }

    func testFirstTransactionCountsOnlySettledMoneyMovement() {
        XCTAssertFalse(HomeStarterChecklistPolicy.hasMadeFirstTransaction(transactions: []))
        XCTAssertFalse(HomeStarterChecklistPolicy.hasMadeFirstTransaction(transactions: [
            transaction(type: "transfer", status: "pending"),
            transaction(type: "transfer", status: "failed"),
            transaction(type: "transfer", status: "reversed"),
            // Requests are asks, not money that moved — under either spelling, even completed.
            transaction(type: "payment_request", status: "completed"),
            transaction(type: "request", status: "completed"),
            transaction(type: " Payment_Request ", status: " COMPLETED "),
            // Money moving back is not a first transaction.
            transaction(type: "transfer_reversal", status: "completed"),
            transaction(type: "mobile_money_refund", status: "completed"),
            // Zero and unparseable amounts moved nothing.
            transaction(type: "transfer", status: "completed", amount: "0"),
            transaction(type: "transfer", status: "completed", amount: "not-a-number"),
            // Unknown statuses fail closed.
            transaction(type: "transfer", status: "mystery_state"),
            // Money the customer *received* is not a transaction they made — even settled.
            transaction(type: "transfer", status: "completed", direction: "credit"),
            transaction(type: "deposit", status: "settled", direction: " CREDIT "),
            // Unknown and missing directions fail closed like unknown statuses.
            transaction(type: "transfer", status: "completed", direction: "sideways"),
            transaction(type: "transfer", status: "completed", direction: ""),
        ]))
        XCTAssertTrue(HomeStarterChecklistPolicy.hasMadeFirstTransaction(transactions: [
            transaction(type: "transfer", status: "completed"),
        ]))
        // Trimming and case-folding apply to genuine rows too.
        XCTAssertTrue(HomeStarterChecklistPolicy.hasMadeFirstTransaction(transactions: [
            transaction(type: " Mobile_Money_Payout ", status: " Settled ", direction: " Debit "),
        ]))
    }

    /// The persisted account-bound markers complete steps even when the live rows no longer
    /// show the evidence: chat deletion, history pagination, and the transactions page being
    /// only the latest slice of one wallet must not resurrect the checklist.
    func testPersistedMilestonesCompleteStepsWithoutLiveEvidence() {
        let checklist = HomeStarterChecklistPolicy.checklist(
            kycStatus: nil,
            messages: [],
            transactions: [],
            hasConfirmedFirstMessage: true,
            hasConfirmedFirstTransaction: true,
            isDemoActive: false
        )
        XCTAssertEqual(checklist?.completedCount, 2)
        XCTAssertEqual(
            checklist?.entries.first(where: { $0.step == .sendFirstMessage })?.isComplete,
            true
        )
        XCTAssertEqual(
            checklist?.entries.first(where: { $0.step == .makeFirstTransaction })?.isComplete,
            true
        )
    }

    /// The live KYC payload blends per-device verification into `status`, so a verified
    /// account on a freshly enrolled iPhone reads "pending" there. The checklist consumes
    /// `account_status` first, which stays verified.
    func testVerifiedAccountWithPendingDeviceStatusStillCompletesIdentity() throws {
        let live = try JSONDecoder().decode(
            KYCStatus.self,
            from: Data(#"{"status":"pending","account_status":"verified"}"#.utf8)
        )
        XCTAssertEqual(live.status, "pending")
        XCTAssertEqual(live.accountStatus, "verified")

        // Exactly Home's selection: account status first, cached profile as fallback.
        let effective = live.accountStatus ?? "pending"
        XCTAssertTrue(HomeStarterChecklistPolicy.identityVerified(kycStatus: effective))
        XCTAssertFalse(HomeStarterChecklistPolicy.identityVerified(kycStatus: live.status))

        // Older backends omit account_status; decoding must not fail and the fallback rules.
        let legacy = try JSONDecoder().decode(
            KYCStatus.self,
            from: Data(#"{"status":"verified"}"#.utf8)
        )
        XCTAssertNil(legacy.accountStatus)
        XCTAssertTrue(
            HomeStarterChecklistPolicy.identityVerified(
                kycStatus: legacy.accountStatus ?? "verified"
            )
        )
    }

    /// Identity verification is substantive and opens full-screen; the rejected half-height
    /// sheet pattern must not come back through the checklist routes.
    func testStarterStepRoutePresentation() {
        XCTAssertEqual(
            HomeStarterStepRoutePolicy.presentation(
                for: .verifyIdentity,
                secureMessagingAvailable: false
            ),
            .fullScreen
        )
        XCTAssertEqual(
            HomeStarterStepRoutePolicy.presentation(
                for: .sendFirstMessage,
                secureMessagingAvailable: true
            ),
            .tabSwitch
        )
        XCTAssertEqual(
            HomeStarterStepRoutePolicy.presentation(
                for: .makeFirstTransaction,
                secureMessagingAvailable: false
            ),
            .walletSheet
        )
    }

    /// "Send first message" must never open a composer that cannot compose. When secure
    /// messaging is not set up on this device the route explains the real next step instead,
    /// and no other step is affected by messaging availability.
    func testSendFirstMessageRouteGatesOnSecureMessagingAvailability() {
        XCTAssertEqual(
            HomeStarterStepRoutePolicy.presentation(
                for: .sendFirstMessage,
                secureMessagingAvailable: false
            ),
            .unavailable(message: HomeStarterStepRoutePolicy.messagingUnavailableMessage)
        )
        XCTAssertFalse(HomeStarterStepRoutePolicy.messagingUnavailableMessage.isEmpty)
    }

    /// The optional server milestone contract only ever adds confirmation, and it is judged
    /// whole: old servers omit the capability and are never asked, a well-formed payload can
    /// confirm, and any malformed, wrong-account, ineligible, off-policy, or off-vocabulary
    /// payload is discarded in its entirety rather than mined for the parts that look right.
    func testStarterMilestonesContractFailsClosed() throws {
        // Exact-key compatibility with the backend's OpenAPI: the one canonical capability key
        // is `starter_checklist` (route onboarding/starter-checklist). No client-side alias.
        XCTAssertEqual(StarterMilestonesDTO.capabilityKey, "starter_checklist")

        let account = "7f9c24e8-3b12-4f4f-9a3e-0c0d1e2f3a4b"
        let otherAccount = "1e50a3c1-88d2-4c6e-b7a4-5f6a7b8c9d0e"

        // The authoritative nested response with the canonical key vocabulary. All three keys
        // are validated even though only message/transaction persist locally; `completed_at`
        // is a required key whose value is null until the milestone completes.
        let authoritative = try JSONDecoder().decode(
            StarterMilestonesDTO.self,
            from: Data(#"""
            {"account_id":"\#(account)","eligible":true,"policy_version":1,
             "milestones":[
               {"key":"verify_identity","status":"completed",
                "completed_at":"2026-08-20T09:00:00Z"},
               {"key":"send_first_message","status":"completed",
                "completed_at":"2026-08-27T10:00:00Z"},
               {"key":"make_first_transaction","status":"pending","completed_at":null}
             ]}
            """#.utf8)
        )
        XCTAssertEqual(authoritative.policyVersion, 1)
        XCTAssertEqual(
            authoritative.confirmedMilestoneKeys(forAccountID: account),
            [
                StarterMilestonesDTO.verifyIdentityMilestoneKey,
                StarterMilestonesDTO.sendFirstMessageMilestoneKey,
            ]
        )
        // The active-account check is canonical UUID equality, not string equality.
        XCTAssertEqual(
            authoritative.confirmedMilestoneKeys(forAccountID: account.uppercased()),
            [
                StarterMilestonesDTO.verifyIdentityMilestoneKey,
                StarterMilestonesDTO.sendFirstMessageMilestoneKey,
            ]
        )
        // A payload speaking for any other account — or no recognisable account — is nil.
        XCTAssertNil(authoritative.confirmedMilestoneKeys(forAccountID: otherAccount))
        XCTAssertNil(authoritative.confirmedMilestoneKeys(forAccountID: "not-a-uuid"))
        XCTAssertNil(authoritative.confirmedMilestoneKeys(forAccountID: ""))

        // `pending` is a valid status that confirms nothing: an all-pending payload is trusted
        // (empty set), not rejected (nil).
        let allPending = try JSONDecoder().decode(
            StarterMilestonesDTO.self,
            from: Data(#"""
            {"account_id":"\#(account)","eligible":true,"policy_version":1,
             "milestones":[
               {"key":"verify_identity","status":"pending","completed_at":null},
               {"key":"send_first_message","status":"pending","completed_at":null},
               {"key":"make_first_transaction","status":"pending","completed_at":null}
             ]}
            """#.utf8)
        )
        XCTAssertEqual(allPending.confirmedMilestoneKeys(forAccountID: account), [])

        // A whitespace-corrupted account_id is evidence of a broken producer; it must be
        // rejected as-is, never trimmed into a match. (In these raw strings `\n`/`\t` reach
        // the decoder as JSON escapes, i.e. real control characters in the decoded ID.)
        let corruptedAccountIDs = [
            #" \#(account)"#,
            #"\#(account) "#,
            #"\n\#(account)\n"#,
            #"\t\#(account)"#,
        ]
        for corrupted in corruptedAccountIDs {
            let payload = try JSONDecoder().decode(
                StarterMilestonesDTO.self,
                from: Data(#"""
                {"account_id":"\#(corrupted)","eligible":true,"policy_version":1,
                 "milestones":[{"key":"send_first_message","status":"completed",
                                "completed_at":"2026-08-27T10:00:00Z"}]}
                """#.utf8)
            )
            XCTAssertNil(payload.confirmedMilestoneKeys(forAccountID: account), corrupted)
        }

        // `eligible` false withholds every confirmation, even of completed milestones.
        let ineligible = try JSONDecoder().decode(
            StarterMilestonesDTO.self,
            from: Data(#"""
            {"account_id":"\#(account)","eligible":false,"policy_version":1,
             "milestones":[{"key":"send_first_message","status":"completed",
                            "completed_at":"2026-08-27T10:00:00Z"}]}
            """#.utf8)
        )
        XCTAssertNil(ineligible.confirmedMilestoneKeys(forAccountID: account))

        // The policy version is an integer with minimum 1; zero and negatives reject whole.
        for badVersion in [0, -1, -2026] {
            let offPolicy = try JSONDecoder().decode(
                StarterMilestonesDTO.self,
                from: Data(#"""
                {"account_id":"\#(account)","eligible":true,"policy_version":\#(badVersion),
                 "milestones":[{"key":"send_first_message","status":"completed",
                                "completed_at":"2026-08-27T10:00:00Z"}]}
                """#.utf8)
            )
            XCTAssertNil(
                offPolicy.confirmedMilestoneKeys(forAccountID: account),
                "policy_version \(badVersion)"
            )
        }

        // Off-vocabulary payloads reject WHOLE — a completed canonical milestone in the same
        // payload must not survive. Covers the retired legacy key names, unknown keys,
        // duplicate keys, and every non-exact status spelling.
        let poisonedMilestoneLists = [
            // Retired legacy keys are unknown vocabulary now, never a quiet synonym.
            #"[{"key":"first_message_sent","status":"completed","completed_at":"2026-08-27T10:00:00Z"}]"#,
            #"[{"key":"first_transaction_settled","status":"completed","completed_at":"2026-08-27T10:00:00Z"}]"#,
            // An unknown key poisons the payload even alongside a valid completed entry.
            #"""
            [{"key":"send_first_message","status":"completed","completed_at":"2026-08-27T10:00:00Z"},
             {"key":"referral_completed","status":"completed","completed_at":"2026-08-27T10:00:00Z"}]
            """#,
            // Duplicate known keys contradict the one-entry-per-milestone contract.
            #"""
            [{"key":"send_first_message","status":"completed","completed_at":"2026-08-27T10:00:00Z"},
             {"key":"send_first_message","status":"pending","completed_at":null}]
            """#,
            // Status vocabulary is exact and lowercase.
            #"[{"key":"send_first_message","status":"COMPLETED","completed_at":"2026-08-27T10:00:00Z"}]"#,
            #"[{"key":"send_first_message","status":" completed ","completed_at":"2026-08-27T10:00:00Z"}]"#,
            #"""
            [{"key":"make_first_transaction","status":"in_progress","completed_at":null},
             {"key":"send_first_message","status":"completed","completed_at":"2026-08-27T10:00:00Z"}]
            """#,
            #"[{"key":"verify_identity","status":"failed","completed_at":null}]"#,
        ]
        for poisoned in poisonedMilestoneLists {
            let payload = try JSONDecoder().decode(
                StarterMilestonesDTO.self,
                from: Data(#"""
                {"account_id":"\#(account)","eligible":true,"policy_version":1,
                 "milestones":\#(poisoned)}
                """#.utf8)
            )
            XCTAssertNil(payload.confirmedMilestoneKeys(forAccountID: account), poisoned)
        }

        // The nested contract is required in full: an empty object, a missing or mistyped
        // field (including a string policy_version and a milestone that omits the required
        // completed_at key) — and the retired flat projection — all fail the whole decode.
        let malformedPayloads = [
            "{}",
            #"{"first_message_sent":true,"first_transaction_settled":false}"#,
            #"{"account_id":"\#(account)","policy_version":1,"milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":"yes","policy_version":1,"milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":true,"milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":"1","milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":"2026-08","milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1.5,"milestones":[]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1,"milestones":[{"key":"send_first_message","completed_at":null}]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1,"milestones":[{"status":"completed","completed_at":null}]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1,"milestones":[{"key":"send_first_message","status":"pending"}]}"#,
            #"{"account_id":"\#(account)","eligible":true,"policy_version":1,"milestones":[{"key":"send_first_message","status":"completed"}]}"#,
        ]
        for malformed in malformedPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(StarterMilestonesDTO.self, from: Data(malformed.utf8)),
                malformed
            )
        }

        // The capability itself fails closed: missing key, null, and false all read as off,
        // and only the backend's exact `starter_checklist` key turns the contract on.
        let withheld = try JSONDecoder().decode(
            CapabilitiesDTO.self,
            from: Data(#"{"currency":{"code":"UGX","scale":"0"},"features":{"starter_checklist":null}}"#.utf8)
        )
        XCTAssertFalse(withheld.supportsFeature(StarterMilestonesDTO.capabilityKey))
        let advertised = try JSONDecoder().decode(
            CapabilitiesDTO.self,
            from: Data(#"{"currency":{"code":"UGX","scale":"0"},"features":{"starter_checklist":true,"starter_milestones":false}}"#.utf8)
        )
        XCTAssertTrue(advertised.supportsFeature(StarterMilestonesDTO.capabilityKey))
    }

    func testChecklistOrderProgressAndDisappearance() {
        let fresh = HomeStarterChecklistPolicy.checklist(
            kycStatus: nil,
            messages: [],
            transactions: [],
            isDemoActive: false
        )
        XCTAssertEqual(fresh?.entries.map(\.step), [
            .verifyIdentity, .sendFirstMessage, .makeFirstTransaction,
        ])
        XCTAssertEqual(fresh?.completedCount, 0)
        XCTAssertEqual(fresh?.totalCount, 3)

        let partial = HomeStarterChecklistPolicy.checklist(
            kycStatus: "verified",
            messages: [message("hi!", isOutgoing: true, state: .sent)],
            transactions: [],
            isDemoActive: false
        )
        XCTAssertEqual(partial?.completedCount, 2)

        // 3 of 3: the checklist leaves Home entirely.
        XCTAssertNil(HomeStarterChecklistPolicy.checklist(
            kycStatus: "approved",
            messages: [message("hi!", isOutgoing: true, state: .read)],
            transactions: [transaction(type: "transfer", status: "completed")],
            isDemoActive: false
        ))

        // The App Review demo account never sees a first-run checklist: its rows are
        // synthetic and must neither show nor satisfy the steps.
        XCTAssertNil(HomeStarterChecklistPolicy.checklist(
            kycStatus: nil,
            messages: [],
            transactions: [],
            isDemoActive: true
        ))
    }

    private func message(
        _ body: String,
        isOutgoing: Bool,
        state: MessageDeliveryState
    ) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: "30000000-0000-0000-0000-000000000001",
            senderId: "10000000-0000-4000-8000-000000000001",
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: state,
            failureReason: nil,
            isOutgoing: isOutgoing,
            attachmentData: nil,
            pendingAttachment: nil
        )
    }

    private func transaction(
        type: String,
        status: String,
        amount: String = "1000",
        direction: String = "debit"
    ) -> WalletTransaction {
        WalletTransaction(
            id: UUID().uuidString,
            walletId: "wallet-1",
            reference: "REF-1",
            amount: amount,
            currency: CurrencyDTO(code: "UGX", scale: "0"),
            type: type,
            direction: direction,
            status: status,
            counterparty: nil,
            note: nil,
            occurredAt: "2026-08-28T08:00:00Z"
        )
    }
}
