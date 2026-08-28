import Foundation
import XCTest
@testable import KitPay

final class ContactSyncTests: XCTestCase {
    func testRecentUnchangedProjectionCanBeReusedOnlyForBackgroundRefresh() {
        XCTAssertTrue(
            ContactSyncServerRefreshPolicy.canReuseLocalProjection(
                snapshotIsUnchanged: true,
                recentlyRefreshed: true,
                requiresAuthorizationRefresh: false,
                forceServerRefresh: false
            )
        )
        XCTAssertFalse(
            ContactSyncServerRefreshPolicy.canReuseLocalProjection(
                snapshotIsUnchanged: true,
                recentlyRefreshed: true,
                requiresAuthorizationRefresh: false,
                forceServerRefresh: true
            )
        )
    }

    func testProjectionReuseStillRejectsChangedStaleOrAuthorizationInvalidatedSnapshots() {
        let inputs = [
            (snapshotIsUnchanged: false, recentlyRefreshed: true, authorization: false),
            (snapshotIsUnchanged: true, recentlyRefreshed: false, authorization: false),
            (snapshotIsUnchanged: true, recentlyRefreshed: true, authorization: true),
        ]

        for input in inputs {
            XCTAssertFalse(
                ContactSyncServerRefreshPolicy.canReuseLocalProjection(
                    snapshotIsUnchanged: input.snapshotIsUnchanged,
                    recentlyRefreshed: input.recentlyRefreshed,
                    requiresAuthorizationRefresh: input.authorization,
                    forceServerRefresh: false
                )
            )
        }
    }

    func testContactFingerprintIsStableAndChangesWithTheSnapshot() {
        let first = ContactSyncSnapshot(
            contacts: [
                ContactSyncEntry(name: "ExampleContact", phone: "+256700000001", favorite: false),
            ],
            omittedCount: 0
        )
        let same = ContactSyncSnapshot(contacts: first.contacts, omittedCount: 0)
        let changed = ContactSyncSnapshot(
            contacts: [
                ContactSyncEntry(name: "ExampleContact A", phone: "+256700000001", favorite: false),
            ],
            omittedCount: 0
        )

        XCTAssertEqual(first.fingerprint, same.fingerprint)
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 64)
    }

    func testContactSyncProgressClampsToAValidFraction() {
        XCTAssertNil(
            ContactSyncProgress(
                phase: .preparing,
                completedUnitCount: 0,
                totalUnitCount: 0
            ).fractionCompleted
        )
        XCTAssertEqual(
            ContactSyncProgress(
                phase: .uploading,
                completedUnitCount: 3,
                totalUnitCount: 4
            ).fractionCompleted,
            0.75
        )
        XCTAssertEqual(
            ContactSyncProgress(
                phase: .complete,
                completedUnitCount: 9,
                totalUnitCount: 4
            ).fractionCompleted,
            1
        )
    }

    func testContactSyncRecoveryPresentationKeepsRoutineStatesSilent() {
        let routineStates: [AutomaticContactSyncState] = [
            .idle,
            .requestingPermission,
            .syncing(
                ContactSyncProgress(
                    phase: .uploading,
                    completedUnitCount: 1,
                    totalUnitCount: 2
                )
            ),
            .synced(uploaded: 12, matched: 4, limitedAccess: false),
            .synced(uploaded: 3, matched: 1, limitedAccess: true),
        ]

        for state in routineStates {
            XCTAssertNil(ContactSyncRecoveryPresentation.presentation(for: state))
        }
    }

    func testContactSyncRecoveryPresentationExposesOnlyActionableFailures() {
        let settings = ContactSyncRecoveryPresentation.presentation(for: .denied)
        XCTAssertEqual(settings, .openSettings)
        XCTAssertEqual(
            settings?.accessibilityIdentifier,
            "contact-sync-recovery.open-settings"
        )

        let retry = ContactSyncRecoveryPresentation.presentation(
            for: .failed("The server is temporarily unavailable.")
        )
        XCTAssertEqual(
            retry,
            .retry(message: "The server is temporarily unavailable.")
        )
        XCTAssertEqual(retry?.accessibilityIdentifier, "contact-sync-recovery.retry")
    }

    func testLimitedContactAccessSyncsSelectedRowsWithoutReprompting() async throws {
        let source = ContactsSourceSpy(
            state: .limited,
            phones: [DeviceContactPhone(name: "ExampleContact", phone: "0700000001")]
        )
        let uploader = ContactsUploaderSpy()
        let outcome = try await ContactSyncCoordinator(
            source: source,
            uploader: uploader
        ).syncAfterExplicitUserAction()

        let requestCount = await source.requestCount
        let payload = await uploader.lastPayload
        XCTAssertTrue(outcome.limitedAccess)
        XCTAssertEqual(outcome.uploadedCount, 1)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(payload.map(\.phone), ["+256700000001"])
    }

    func testOpaqueContactCursorIsEncodedExactlyOnceInTheFinalURL() throws {
        let url = try XCTUnwrap(
            APIEndpointPolicy.url(
                baseURL: try XCTUnwrap(URL(string: "https://pay.kit.africa/api/kit-wallet/v1/")),
                path: "contacts",
                queryItems: [
                    URLQueryItem(name: "limit", value: "500"),
                    URLQueryItem(name: "cursor", value: "abc+/= next"),
                ]
            )
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://pay.kit.africa/api/kit-wallet/v1/contacts?limit=500&cursor=abc%2B%2F%3D%20next"
        )
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value,
            "abc+/= next"
        )
    }

    func testRootMenuHidesOnlyInsideTheSelectedConversationTab() {
        XCTAssertTrue(
            RootTabBarPolicy.isVisible(
                selectedTab: 1,
                messagesTab: 1,
                isConversationPresented: false,
                isAccountDeletionSubmissionActive: false
            )
        )
        XCTAssertFalse(
            RootTabBarPolicy.isVisible(
                selectedTab: 1,
                messagesTab: 1,
                isConversationPresented: true,
                isAccountDeletionSubmissionActive: false
            )
        )
        XCTAssertTrue(
            RootTabBarPolicy.isVisible(
                selectedTab: 0,
                messagesTab: 1,
                isConversationPresented: true,
                isAccountDeletionSubmissionActive: false
            )
        )
        XCTAssertFalse(
            RootTabBarPolicy.isVisible(
                selectedTab: 3,
                messagesTab: 1,
                isConversationPresented: false,
                isAccountDeletionSubmissionActive: true
            )
        )
    }

    func testRootMenuStepsAsideForAPushedProfileSettingsPage() {
        XCTAssertFalse(
            RootTabBarPolicy.isVisible(
                selectedTab: 3,
                messagesTab: 1,
                isConversationPresented: false,
                profileTab: 3,
                isProfileDetailPresented: true,
                isAccountDeletionSubmissionActive: false
            )
        )
        XCTAssertTrue(
            RootTabBarPolicy.isVisible(
                selectedTab: 3,
                messagesTab: 1,
                isConversationPresented: false,
                profileTab: 3,
                isProfileDetailPresented: false,
                isAccountDeletionSubmissionActive: false
            )
        )
        // A detail screen left open under Profile must never hide the menu on another tab.
        XCTAssertTrue(
            RootTabBarPolicy.isVisible(
                selectedTab: 0,
                messagesTab: 1,
                isConversationPresented: true,
                profileTab: 3,
                isProfileDetailPresented: true,
                isAccountDeletionSubmissionActive: false
            )
        )
    }

    func testFloatingRootMenuIsLegibleAndSitsLowerWithoutSacrificingClearance() {
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.scrollClearance, 0)
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.barTopPadding, 0)

        // The trim is deliberately neutral: every metric below is stated at the size it should
        // render at rather than being a larger number shrunk by a factor, which had left the
        // icons and captions smaller than the ones iOS draws in its own tab bar.
        XCTAssertEqual(RootTabBarLayoutPolicy.visualScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(RootTabBarLayoutPolicy.iconPointSize, 23, accuracy: 0.0001)
        XCTAssertEqual(RootTabBarLayoutPolicy.captionPointSize, 11, accuracy: 0.0001)
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.iconPointSize,
            RootTabBarLayoutPolicy.captionPointSize
        )

        // The icon is what people aim at, so the button is sized around it rather than carrying
        // dead height: a floating capsule reads better shorter than a docked bar, and the row is
        // still a comfortable target.
        XCTAssertEqual(RootTabBarLayoutPolicy.baseButtonHeight, 50, accuracy: 0.0001)
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.baseButtonHeight,
            RootTabBarLayoutPolicy.iconPointSize + RootTabBarLayoutPolicy.captionPointSize
        )

        // The capsule floats: it is inset from both screen edges and from the buttons inside it,
        // and its assumed height is derived from those insets rather than guessed separately —
        // a stale guess made the very first frame of every page scroll under the menu.
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.capsuleInset, 0)
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.interButtonSpacing, 0)
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.regularHorizontalInset,
            RootTabBarLayoutPolicy.compactHorizontalInset
        )
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.compactHorizontalInset, 0)
        XCTAssertEqual(
            RootTabBarLayoutPolicy.estimatedBarHeight,
            RootTabBarLayoutPolicy.baseButtonHeight
                + (RootTabBarLayoutPolicy.capsuleInset * 2)
                + RootTabBarLayoutPolicy.barTopPadding,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: false),
            RootTabBarLayoutPolicy.minimumInteractiveDimension
        )
        // An accessibility text size grows the hit target instead of shrinking with the rest.
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: true),
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: false)
        )

        XCTAssertEqual(RootTabBarLayoutPolicy.verticalDropFraction, 0.20, accuracy: 0.0001)
        XCTAssertEqual(
            RootTabBarLayoutPolicy.verticalDrop,
            RootTabBarLayoutPolicy.baseButtonHeight * 0.20,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: false),
            RootTabBarLayoutPolicy.baseButtonHeight * RootTabBarLayoutPolicy.visualScale,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            RootTabBarLayoutPolicy.verticalDrop,
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: false)
        )
    }

    func testSlidingAcrossTheMenuOnlySwitchesPageOnRelease() {
        let width: CGFloat = 320
        let tabs = 4
        let horizontal = CGSize(width: 90, height: 6)

        // Mid-slide the menu shows where the finger is, while the selection — and so the page —
        // is still the one the customer started on. Switching under the finger meant every tab
        // crossed on the way to the intended one was loaded and thrown away again.
        let underFinger = RootTabBarSlidePolicy.tabIndex(atX: 250, stripWidth: width, count: tabs)
        XCTAssertEqual(underFinger, 3)
        XCTAssertEqual(
            RootTabBarSlidePolicy.highlightedIndex(selection: 0, slidingTo: underFinger),
            3
        )

        // The release is what commits it.
        XCTAssertEqual(
            RootTabBarSlidePolicy.committedTabIndex(
                translation: horizontal,
                x: 250,
                stripWidth: width,
                count: tabs
            ),
            3
        )

        // With no finger down the menu simply shows the selection.
        XCTAssertEqual(
            RootTabBarSlidePolicy.highlightedIndex(selection: 2, slidingTo: nil),
            2
        )
    }

    func testReachingPastTheMenuIsNotASlide() {
        // Someone swiping up over the capsule to get at the page behind it must not be treated as
        // choosing a tab, however far across the row the finger happens to be.
        let vertical = CGSize(width: 12, height: -140)
        XCTAssertFalse(RootTabBarSlidePolicy.isSlide(translation: vertical))
        XCTAssertNil(
            RootTabBarSlidePolicy.committedTabIndex(
                translation: vertical,
                x: 250,
                stripWidth: 320,
                count: 4
            )
        )
        XCTAssertTrue(
            RootTabBarSlidePolicy.isSlide(translation: CGSize(width: 90, height: 6))
        )
        XCTAssertGreaterThan(RootTabBarSlidePolicy.activationDistance, 0)
    }

    func testAFingerRunningOffTheEndOfTheMenuStillPointsAtTheLastTab() {
        XCTAssertEqual(
            RootTabBarSlidePolicy.tabIndex(atX: 999, stripWidth: 320, count: 4),
            3
        )
        XCTAssertEqual(
            RootTabBarSlidePolicy.tabIndex(atX: -40, stripWidth: 320, count: 4),
            0
        )
        // Every button owns exactly its own quarter of the row.
        XCTAssertEqual(RootTabBarSlidePolicy.tabIndex(atX: 0, stripWidth: 320, count: 4), 0)
        XCTAssertEqual(RootTabBarSlidePolicy.tabIndex(atX: 79, stripWidth: 320, count: 4), 0)
        XCTAssertEqual(RootTabBarSlidePolicy.tabIndex(atX: 81, stripWidth: 320, count: 4), 1)
        XCTAssertEqual(RootTabBarSlidePolicy.tabIndex(atX: 161, stripWidth: 320, count: 4), 2)

        // Before the row has been measured there is nothing to point at.
        XCTAssertNil(RootTabBarSlidePolicy.tabIndex(atX: 100, stripWidth: 0, count: 4))
        XCTAssertNil(RootTabBarSlidePolicy.tabIndex(atX: 100, stripWidth: 320, count: 0))
    }

    func testPagesInsideATabAddNoBottomPaddingOfTheirOwn() {
        // Clearance arrives as scroll *content* margin, so the scroll view still lays out edge to
        // edge and rows stay visible travelling behind the glass. A page adding its own bottom
        // padding on top of that stacks and reads as the list ending early.
        XCTAssertEqual(RootTabBarLayoutPolicy.pageBottomPadding, 0)
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.scrollClearance,
            RootTabBarLayoutPolicy.pageBottomPadding
        )
    }

    func testFloatingRootMenuClearanceCoversTheCapsuleItDraws() {
        // The menu is an overlay, so nothing is reserved automatically. This margin is the only
        // thing keeping a page's last row reachable, and it has to cover the measured capsule, the
        // drop that puts the capsule lower than the frame it was measured from, and the resting
        // gap above it.
        let barHeight: CGFloat = 78
        XCTAssertEqual(
            RootTabBarLayoutPolicy.contentClearance(barHeight: barHeight),
            barHeight
                + RootTabBarLayoutPolicy.verticalDrop
                + RootTabBarLayoutPolicy.scrollClearance
        )
        XCTAssertGreaterThan(
            RootTabBarLayoutPolicy.contentClearance(barHeight: barHeight),
            barHeight + RootTabBarLayoutPolicy.verticalDrop
        )
        // A missing or nonsensical measurement must never produce a negative margin.
        XCTAssertGreaterThanOrEqual(
            RootTabBarLayoutPolicy.contentClearance(barHeight: -50),
            RootTabBarLayoutPolicy.scrollClearance
        )
        XCTAssertGreaterThan(RootTabBarLayoutPolicy.estimatedBarHeight, 0)
    }

    func testRootMenuButtonsKeepAnAccessibleHitHeight() {
        XCTAssertGreaterThanOrEqual(
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: false),
            RootTabBarLayoutPolicy.minimumInteractiveDimension
        )
        XCTAssertGreaterThanOrEqual(
            RootTabBarLayoutPolicy.buttonMinimumHeight(accessibilitySize: true),
            RootTabBarLayoutPolicy.minimumInteractiveDimension
        )
    }

    func testExampleContactUgandaNumberNormalizesExactlyAcrossCommonAddressBookForms() {
        let expected = "+256700000001"
        for input in [
            "0700000001",
            "0700 000 001",
            "700-000-001",
            "256 700 000 001",
            "+256 (700) 000-001",
            "00 256 0700 000 001",
        ] {
            XCTAssertEqual(
                PhoneIdentityNormalizer.normalizedE164(input, context: .uganda),
                expected,
                "Unexpected normalization for \(input)"
            )
        }
    }

    func testPhoneIdentityNormalizesLocalCountryCodedAndInternationalForms() {
        let uganda = PhoneIdentityContext.uganda

        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("0772 123 456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("772-123-456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("256 (772) 123 456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("+256 (772) 123-456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("00 44 20 7946 0958", context: uganda),
            "+442079460958"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("011 44 20 7946 0958", context: uganda),
            "+442079460958"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("+256 (0) 772 123 456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("00 256 0772 123 456", context: uganda),
            "+256772123456"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("٠٧٧٢ ١٢٣ ٤٥٦", context: uganda),
            "+256772123456"
        )
    }

    func testPhoneIdentityUsesProfileRegionForNationalNumbers() {
        let uk = PhoneIdentityContext(referencePhone: "+44 7700 900123")
        XCTAssertEqual(uk.countryCallingCode, "44")
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("020 7946 0958", context: uk),
            "+442079460958"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("44 20 7946 0958", context: uk),
            "+442079460958"
        )

        let northAmerica = PhoneIdentityContext(referencePhone: "+1 (415) 555-2671")
        XCTAssertNil(northAmerica.nationalTrunkPrefix)
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("415 555 2671", context: northAmerica),
            "+14155552671"
        )

        let profileCountryFallback = PhoneIdentityContext(
            referencePhone: nil,
            countryISOCode: " gb "
        )
        XCTAssertEqual(profileCountryFallback.countryCallingCode, "44")
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("020 7946 0958", context: profileCountryFallback),
            "+442079460958"
        )

        let russia = PhoneIdentityContext(countryCallingCode: "7", nationalTrunkPrefix: "8")
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("8 812 555 1212", context: russia),
            "+78125551212"
        )
        XCTAssertEqual(
            PhoneIdentityNormalizer.normalizedE164("+7 812 555 1212", context: russia),
            "+78125551212"
        )
    }

    func testUserProfileDecodesServerCountryCode() throws {
        let data = try XCTUnwrap(#"{"id":"user-1","phone":"+256772123456","country_code":"UG"}"#.data(using: .utf8))
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        XCTAssertEqual(profile.countryCode, "UG")
    }

    func testPhoneIdentityRejectsAmbiguousOrInvalidSyntax() {
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164("*165#"))
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164("+256772123456 ext 4"))
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164("+256+772123456"))
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164("011 999 772 123 456"))
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164("123"))
        XCTAssertNil(PhoneIdentityNormalizer.normalizedE164(String(repeating: "7", count: 40)))
    }

    func testPayloadContainsOnlyDocumentedContactFields() throws {
        let request = SyncContactsRequest(contacts: [
            ContactSyncEntry(name: "Amina", phone: "+256772123456", favorite: false),
        ])

        let data = try JSONEncoder().encode(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["contacts"])
        let contacts = try XCTUnwrap(root["contacts"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(contacts.first).keys), ["name", "phone", "favorite"])
        XCTAssertNil(contacts.first?["device_identifier"])
        XCTAssertNil(contacts.first?["email"])
    }

    func testSnapshotNormalizesUgandanNumbersAndLastDuplicateWins() {
        let snapshot = ContactSyncNormalizer.snapshot(from: [
            DeviceContactPhone(name: "First name", phone: "0772 123 456"),
            DeviceContactPhone(name: "Second name", phone: "+256 (772) 123-456"),
            DeviceContactPhone(name: "International", phone: "00 44 20 7946 0958"),
        ])

        XCTAssertEqual(snapshot.contacts, [
            ContactSyncEntry(name: "Second name", phone: "+256772123456", favorite: false),
            ContactSyncEntry(name: "International", phone: "+442079460958", favorite: false),
        ])
        XCTAssertEqual(snapshot.omittedCount, 0)
    }

    func testSnapshotRejectsServerInvalidRowsAndAppliesFieldLimits() {
        let longName = String(repeating: "F", count: 200)
        let snapshot = ContactSyncNormalizer.snapshot(from: [
            DeviceContactPhone(name: "Service", phone: "*165#"),
            DeviceContactPhone(name: longName, phone: "+256 772 987 655"),
            DeviceContactPhone(name: "Too long", phone: String(repeating: "7", count: 33)),
        ])

        XCTAssertEqual(snapshot.contacts.count, 1)
        XCTAssertEqual(snapshot.contacts[0].name.count, 160)
        XCTAssertEqual(snapshot.contacts[0].phone, "+256772987655")
    }

    func testSnapshotDeduplicatesNationalAndInternationalFormsUsingContext() {
        let uk = PhoneIdentityContext(countryCallingCode: "44")
        let snapshot = ContactSyncNormalizer.snapshot(
            from: [
                DeviceContactPhone(name: "First", phone: "020 7946 0958"),
                DeviceContactPhone(name: "Latest", phone: "+44 20 7946 0958"),
            ],
            context: uk
        )

        XCTAssertEqual(snapshot.contacts, [
            ContactSyncEntry(name: "Latest", phone: "+442079460958", favorite: false),
        ])
    }

    func testRecipientDirectoryDeduplicatesAndAlwaysPlacesKitUsersFirst() throws {
        let kitA = "550e8400-e29b-41d4-a716-446655440001"
        let kitB = "550e8400-e29b-41d4-a716-446655440002"
        let contacts = [
            contact(id: "invite-z", name: "Zara Invite", phone: "0701 000 003", kitUser: false, favorite: true),
            contact(id: kitB, name: "Brian", phone: "+256 701 000 002", kitUser: true),
            contact(id: "invite-duplicate", name: "Address-book Brian", phone: "0701 000 002", kitUser: false, favorite: true),
            contact(id: "invite-a", name: "Amina Invite", phone: "+256701000004", kitUser: false),
            contact(id: kitA, name: "Aisha", phone: "256 701 000 001", kitUser: true, favorite: true),
        ]

        let ordered = ContactRecipientDirectory.ordered(contacts)
        XCTAssertEqual(ordered.map(\.id), [kitA, kitB, "invite-z", "invite-a"])
        let sections = ContactRecipientDirectory.sections(contacts)
        XCTAssertEqual(sections.kitPay.map(\.id), [kitA, kitB])
        XCTAssertEqual(sections.invitations.map(\.id), ["invite-z", "invite-a"])

        let brian = try XCTUnwrap(ordered.first(where: { $0.id == kitB }))
        XCTAssertTrue(brian.isKitUser == true)
        XCTAssertTrue(brian.favorite == true)
        XCTAssertEqual(brian.phone, "+256701000002")
    }

    func testPartialServerUnionIsRestrictedToThisDevicesSnapshot() {
        let visible = contact(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "ExampleContact",
            phone: "+256700000001",
            kitUser: true
        )
        let otherDeviceOnly = contact(
            id: "invite-other-device",
            name: "Other device",
            phone: "+256772000999",
            kitUser: false
        )

        XCTAssertEqual(
            ContactRecipientDirectory.restrictedToSnapshot(
                [otherDeviceOnly, visible],
                entries: [
                    ContactSyncEntry(
                        name: "ExampleContact",
                        phone: "+256700000001",
                        favorite: false
                    ),
                ]
            ).map(\.id),
            [visible.id]
        )
    }

    func testRecipientDirectoryKeepsValidPublicUserIdWhenDuplicateMetadataIsMalformed() throws {
        let validId = "550e8400-e29b-41d4-a716-446655440001"
        let contacts = [
            contact(
                id: "not-a-public-user-id",
                name: "Malformed Kit row",
                phone: "0772 123 456",
                kitUser: true
            ),
            contact(
                id: validId.uppercased(),
                name: "Grace on Kit",
                phone: "+256772123456",
                kitUser: true
            ),
        ]

        let sections = ContactRecipientDirectory.sections(contacts)
        let recipient = try XCTUnwrap(sections.kitPay.first)
        XCTAssertEqual(sections.kitPay.count, 1)
        XCTAssertTrue(sections.invitations.isEmpty)
        XCTAssertEqual(recipient.id, validId)
        XCTAssertEqual(ContactRecipientDirectory.recipientUserId(for: recipient), validId)
    }

    func testRecipientDirectoryNeverTreatsAddressBookRowIdAsUserRecipient() {
        let malformed = contact(
            id: "42",
            name: "Unaddressable row",
            phone: "+256701555999",
            kitUser: true
        )

        let sections = ContactRecipientDirectory.sections([malformed])
        XCTAssertTrue(sections.kitPay.isEmpty)
        XCTAssertEqual(sections.invitations.map(\.id), ["42"])
        XCTAssertNil(ContactRecipientDirectory.recipientUserId(for: malformed))
    }

    func testRecipientSectionsSearchMatchesLocalPhoneNameAndTag() {
        let graceId = "550e8400-e29b-41d4-a716-446655440003"
        let contacts = [
            contact(
                id: graceId,
                name: "Gráce Nakato",
                phone: "+256772987654",
                kitUser: true,
                tag: "grace_n"
            ),
            contact(id: "invite", name: "Invite Me", phone: "+256701555999", kitUser: false),
        ]

        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: "0772 987 654").kitPay.map(\.id),
            [graceId]
        )
        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: "0772").kitPay.map(\.id),
            [graceId]
        )
        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: "grace").kitPay.map(\.id),
            [graceId]
        )
        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: "@GRACE_N").kitPay.map(\.id),
            [graceId]
        )
        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: ":GRACE_N").kitPay.map(\.id),
            [graceId]
        )
        XCTAssertTrue(
            ContactRecipientDirectory.sections(contacts, query: ":").kitPay.isEmpty,
            "A bare tag marker must not match every tagged contact"
        )
        XCTAssertEqual(
            ContactRecipientDirectory.sections(contacts, query: "0701 555 999").invitations.map(\.id),
            ["invite"]
        )
    }

    func testKitUserDirectoryQueryUsesTheLiveSearchContract() throws {
        XCTAssertEqual(KitUserDirectorySearch.remoteQuery(from: " @examplemerchant "), "examplemerchant")
        XCTAssertEqual(KitUserDirectorySearch.remoteQuery(from: ":examplemerchant"), "examplemerchant")
        XCTAssertNil(KitUserDirectorySearch.remoteQuery(from: "examplemerchant"))
        XCTAssertNil(KitUserDirectorySearch.remoteQuery(from: "@h"))
        XCTAssertNil(KitUserDirectorySearch.remoteQuery(from: ":"))

        let queryItems = try XCTUnwrap(
            KitUserDirectorySearch.queryItems(query: "herb zo")
        )
        let url = try XCTUnwrap(
            APIEndpointPolicy.url(
                baseURL: try XCTUnwrap(
                    URL(string: "https://pay.kit.africa/api/kit-wallet/v1/")
                ),
                path: "search",
                queryItems: queryItems
            )
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://pay.kit.africa/api/kit-wallet/v1/search?q=herb%20zo&types%5B%5D=users&limit=25"
        )
    }

    func testKitUserDirectoryKeepsSavedKitContactsFirstAndRejectsRemoteInvitations() throws {
        let savedID = "550e8400-e29b-41d4-a716-446655440020"
        let discoveredID = "550e8400-e29b-41d4-a716-446655440021"
        let ownID = "550e8400-e29b-41d4-a716-446655440022"
        let payload = Data("""
        {
          "items": [
            {
              "type": "users",
              "id": "\(savedID.uppercased())",
              "title": "Server name must not replace saved name",
              "subtitle": "@examplemerchant",
              "metadata": {"avatar_url": "https://pay.kit.africa/media/saved.jpg"}
            },
            {
              "type": "users",
              "id": "\(discoveredID)",
              "title": "ExampleMerchant Shop",
              "subtitle": "@examplemerchant_shop",
              "metadata": {"avatar_url": "https://pay.kit.africa/media/examplemerchant.jpg"}
            },
            {
              "type": "contacts",
              "id": "private-contact-row",
              "title": "Must never become an invitation",
              "subtitle": null,
              "metadata": null
            },
            {
              "type": "users",
              "id": "not-a-public-user-id",
              "title": "Malformed",
              "subtitle": "@malformed",
              "metadata": null
            },
            {
              "type": "users",
              "id": "\(ownID)",
              "title": "Current user",
              "subtitle": "@me",
              "metadata": null
            }
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KitUserSearchResultListDTO.self, from: payload)
        let local = [
            contact(
                id: savedID,
                name: "ExampleMerchant in Contacts",
                phone: "+256772000020",
                kitUser: true,
                tag: "examplemerchant"
            ),
            contact(
                id: "invite-examplemerchant",
                name: "ExampleMerchant Invite",
                phone: "+256772000099",
                kitUser: false
            ),
        ]

        let sections = KitUserDirectorySearch.sections(
            localContacts: local,
            remoteResults: try XCTUnwrap(response.items),
            query: ":examplemerchant",
            excludingUserID: ownID
        )

        XCTAssertEqual(sections.savedKitPay.map(\.id), [savedID])
        XCTAssertEqual(sections.directoryKitPay.map(\.id), [discoveredID])
        XCTAssertEqual(sections.kitPay.map(\.name), ["ExampleMerchant in Contacts", "ExampleMerchant Shop"])
        XCTAssertEqual(sections.directoryKitPay.first?.tag, "examplemerchant_shop")
        XCTAssertEqual(sections.directoryKitPay.first?.phone, "")
        XCTAssertEqual(
            sections.directoryKitPay.first?.avatarURL,
            "https://pay.kit.africa/media/examplemerchant.jpg"
        )
        XCTAssertTrue(sections.invitations.isEmpty)
        XCTAssertFalse(sections.invitations.contains { $0.name == "Must never become an invitation" })
    }

    func testExampleContactAppearsInKitSectionAndMatchesLocalNumber() {
        let exampleContactID = "550e8400-e29b-41d4-a716-446655440015"
        let contacts = [
            contact(
                id: "invite-row",
                name: "Amina Invite",
                phone: "+256701555999",
                kitUser: false
            ),
            contact(
                id: exampleContactID,
                name: "ExampleContact",
                phone: "+256700000001",
                kitUser: true,
                tag: "example_contact"
            ),
        ]

        let allSections = ContactRecipientDirectory.sections(contacts)
        XCTAssertEqual(allSections.kitPay.map(\.id), [exampleContactID])
        XCTAssertEqual(allSections.invitations.map(\.id), ["invite-row"])
        XCTAssertEqual(
            ContactRecipientDirectory.sections(
                contacts,
                query: "0700000001",
                context: .uganda
            ).kitPay.map(\.id),
            [exampleContactID]
        )
    }

    func testConversationPresentationPrefersSavedContactNameAndMemberPhoto() throws {
        let currentUserID = "550e8400-e29b-41d4-a716-446655440001"
        let exampleContactUserID = "550e8400-e29b-41d4-a716-446655440015"
        let conversation = Conversation(
            id: "550e8400-e29b-41d4-a716-446655440099",
            title: "Server profile name",
            participantUserIds: [currentUserID, exampleContactUserID.uppercased()],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let saved = WalletContactDTO(
            id: exampleContactUserID,
            contactId: "iphone-contact-example_contact",
            name: "ExampleContact in Contacts",
            phone: "+256700000001",
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: "example_contact",
            avatarURL: nil,
            receivingWalletId: nil
        )
        let member = WalletContactDTO(
            id: exampleContactUserID,
            contactId: nil,
            name: "Server profile name",
            phone: "+256700000001",
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: "example_contact",
            avatarURL: "https://pay.kit.africa/media/example_contact.jpg",
            receivingWalletId: nil
        )

        let presentation = ConversationContactPresentationPolicy.presentation(
            for: conversation,
            currentUserID: currentUserID.uppercased(),
            contacts: [member, saved]
        )

        XCTAssertEqual(presentation.recipientUserID, exampleContactUserID)
        XCTAssertEqual(presentation.displayName, "ExampleContact in Contacts")
        XCTAssertEqual(presentation.contact, saved)
        XCTAssertEqual(
            presentation.avatarURL,
            "https://pay.kit.africa/media/example_contact.jpg"
        )
    }

    func testConversationPresentationNeverGuessesRecipientFromAmbiguousRoster() {
        let conversation = Conversation(
            id: "550e8400-e29b-41d4-a716-446655440099",
            title: "  Study group  ",
            participantUserIds: [
                "550e8400-e29b-41d4-a716-446655440001",
                "550e8400-e29b-41d4-a716-446655440015",
                "550e8400-e29b-41d4-a716-446655440016",
            ],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let presentation = ConversationContactPresentationPolicy.presentation(
            for: conversation,
            currentUserID: "550e8400-e29b-41d4-a716-446655440001",
            contacts: []
        )

        XCTAssertNil(presentation.recipientUserID)
        XCTAssertNil(presentation.contact)
        XCTAssertNil(presentation.avatarURL)
        XCTAssertEqual(presentation.displayName, "Study group")
    }

    func testSnapshotSupportsMoreThanTenThousandNumbersWithoutDroppingExampleContact() {
        var phones = (0 ..< 10_000).map { index in
            DeviceContactPhone(
                name: "Contact \(index)",
                phone: String(format: "0700%06d", index)
            )
        }
        phones.append(DeviceContactPhone(name: "ExampleContact", phone: "0701000001"))

        let snapshot = ContactSyncNormalizer.snapshot(from: phones)

        XCTAssertEqual(snapshot.contacts.count, 10_001)
        XCTAssertEqual(snapshot.omittedCount, 0)
        XCTAssertEqual(snapshot.contacts.last?.name, "ExampleContact")
        XCTAssertEqual(snapshot.contacts.last?.phone, "+256701000001")
    }

    func testDeniedAccessNeverReadsOrUploadsContacts() async {
        let source = ContactsSourceSpy(state: .denied)
        let uploader = ContactsUploaderSpy()
        let coordinator = ContactSyncCoordinator(source: source, uploader: uploader)

        do {
            _ = try await coordinator.syncAfterExplicitUserAction()
            XCTFail("Expected contact access to be denied")
        } catch {
            XCTAssertEqual(error as? ContactSyncError, .accessDenied)
        }

        let readCount = await source.readCount
        let requestCount = await source.requestCount
        let uploadCount = await uploader.uploadCount
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(uploadCount, 0)
    }

    func testNotDeterminedAccessDoesNotUploadWhenPromptIsDeclined() async {
        let source = ContactsSourceSpy(state: .notDetermined, grantsAccess: false)
        let uploader = ContactsUploaderSpy()
        let coordinator = ContactSyncCoordinator(source: source, uploader: uploader)

        _ = try? await coordinator.syncAfterExplicitUserAction()

        let requestCount = await source.requestCount
        let readCount = await source.readCount
        let uploadCount = await uploader.uploadCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(uploadCount, 0)
    }

    func testGrantedPromptReadsAndUploadsExampleContactWithCanonicalUgandaIdentity() async throws {
        let source = ContactsSourceSpy(
            state: .notDetermined,
            grantsAccess: true,
            phones: [DeviceContactPhone(name: "  ExampleContact  ", phone: "0700000001")]
        )
        let uploader = ContactsUploaderSpy()
        let coordinator = ContactSyncCoordinator(source: source, uploader: uploader)

        let outcome = try await coordinator.syncAfterExplicitUserAction()
        let payload = await uploader.lastPayload

        XCTAssertEqual(outcome.uploadedCount, 1)
        XCTAssertEqual(payload, [
            ContactSyncEntry(name: "ExampleContact", phone: "+256700000001", favorite: false),
        ])
    }

    func testExplicitSyncUsesSignedInPhoneRegionWithoutChangingConsentBoundary() async throws {
        let source = ContactsSourceSpy(
            state: .allowed,
            phones: [DeviceContactPhone(name: "London Office", phone: "020 7946 0958")]
        )
        let uploader = ContactsUploaderSpy()
        let coordinator = ContactSyncCoordinator(source: source, uploader: uploader)

        _ = try await coordinator.syncAfterExplicitUserAction(
            context: PhoneIdentityContext(referencePhone: "+44 7700 900123")
        )

        let payload = await uploader.lastPayload
        XCTAssertEqual(payload, [
            ContactSyncEntry(name: "London Office", phone: "+442079460958", favorite: false),
        ])
        let requestCount = await source.requestCount
        XCTAssertEqual(requestCount, 0)
    }
}

private func contact(
    id: String,
    name: String,
    phone: String,
    kitUser: Bool,
    favorite: Bool = false,
    tag: String? = nil
) -> WalletContactDTO {
    WalletContactDTO(
        id: id,
        contactId: "contact-\(id)",
        name: name,
        phone: phone,
        isKitUser: kitUser,
        favorite: favorite,
        status: nil,
        tag: tag,
        avatarURL: nil,
        receivingWalletId: nil
    )
}

private actor ContactsSourceSpy: DeviceContactsProviding {
    nonisolated let state: ContactAccessState
    nonisolated let grantsAccess: Bool
    nonisolated let phones: [DeviceContactPhone]
    private(set) var requestCount = 0
    private(set) var readCount = 0

    init(
        state: ContactAccessState,
        grantsAccess: Bool = false,
        phones: [DeviceContactPhone] = []
    ) {
        self.state = state
        self.grantsAccess = grantsAccess
        self.phones = phones
    }

    nonisolated func accessState() -> ContactAccessState { state }

    func requestAccess() async throws -> Bool {
        requestCount += 1
        return grantsAccess
    }

    func phoneNumbers() async throws -> [DeviceContactPhone] {
        readCount += 1
        return phones
    }
}

private actor ContactsUploaderSpy: ContactSyncUploading {
    private(set) var uploadCount = 0
    private(set) var lastPayload: [ContactSyncEntry] = []

    func syncContacts(_ contacts: [ContactSyncEntry]) async throws -> ContactListDTO {
        uploadCount += 1
        lastPayload = contacts
        return ContactListDTO(items: [], page: nil)
    }
}
