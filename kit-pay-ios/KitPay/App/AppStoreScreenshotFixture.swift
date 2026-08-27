import Foundation

#if DEBUG && APP_STORE_SCREENSHOTS

/// Synthetic App Store artwork data. This code is present only in the dedicated Debug screenshot
/// build and still requires an explicit launch argument, so an ordinary Debug run cannot enter it.
enum AppStoreScreenshotFixture {
    static let launchArgument = "--kit-app-store-screenshot-fixture-v1"
    static let compiledFixtureMarker = "KITPAY_APP_STORE_SCREENSHOT_FIXTURE_V1"
    static let presentationNow = timestamp("2026-08-24T09:41:00Z")

    static var isActive: Bool {
        _ = compiledFixtureMarker
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static let ownerID = "11111111-1111-4111-8111-111111111111"
    static let aminaID = "22222222-2222-4222-8222-222222222222"
    static let brianID = "33333333-3333-4333-8333-333333333333"
    static let claireID = "44444444-4444-4444-8444-444444444444"
    static let danielID = "55555555-5555-4555-8555-555555555555"
    static let estherID = "66666666-6666-4666-8666-666666666666"
    static let frankID = "77777777-7777-4777-8777-777777777777"
    static let graceID = "88888888-8888-4888-8888-888888888888"
    static let henryID = "99999999-9999-4999-8999-999999999999"

    static let primaryConversationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let walletID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    static var capabilities: CapabilitiesDTO {
        CapabilitiesDTO(
            apiVersion: "2026-08-24",
            currency: currency,
            features: [
                "wallets": true,
                "internal_transfers": true,
                "payment_requests": true,
                "mobile_money": true,
                "bank_transfers": true,
                "bills": true,
                "airtime": true,
                "merchant_payments": true,
                "qr_payments": true,
                "messaging": true,
                "media": true,
                "profile_avatars": true,
                "calls": true,
                "kyc": true,
                "transfer_acceptance": true,
            ],
            authentication: [
                "phone_otp": true,
                "email_password": true,
                "mfa": true,
            ],
            protocols: CapabilityProtocolsDTO(
                messaging: MessagingProtocolCapabilityDTO(
                    ready: true,
                    version: SecureMessagingWire.protocolVersion,
                    suite: SecureMessagingWire.protocolSuite,
                    postQuantum: true,
                    richMedia: nil
                )
            )
        )
    }

    static var state: PersistedState {
        var fixture = PersistedState.empty
        fixture.profile = UserProfile(
            id: ownerID,
            name: "Kit Pay Demo",
            email: "review@kit.africa",
            phone: "+256 700 000 000",
            countryCode: "UG",
            tag: "kitpay_demo",
            avatarURL: nil,
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: true,
            emailVerified: true,
            phoneVerified: true,
            profileSetupRequired: false
        )
        fixture.communicationOwnerUserID = ownerID
        fixture.wallets = [
            Wallet(
                id: walletID,
                name: "Everyday wallet",
                accountNumber: "•••• 2048",
                accountType: "personal",
                currency: currency,
                balances: WalletBalances(available: "2450750", ledger: "2450750"),
                status: "active",
                isPrimary: true
            ),
        ]
        fixture.selectedWalletId = walletID
        fixture.transactions = transactions
        fixture.contacts = contacts
        fixture.conversations = conversations
        fixture.messages = messages
        fixture.calls = calls
        fixture.pinnedConversationIds = [primaryConversationID]
        fixture.mutedConversationIds = []
        fixture.communicationPrivacy = CommunicationPrivacyCache(
            ownerUserId: ownerID,
            preferences: communicationPreferences,
            blocks: [],
            refreshedAt: timestamp("2026-08-24T09:40:00Z")
        )
        var secureMessaging = SecureMessagingPersistentState.empty
        secureMessaging.enrollment = SecureMessagingEnrollmentBinding(
            userID: ownerID,
            serverDeviceID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            signalDeviceID: 1,
            registrationID: 7,
            enrollmentEpoch: 1,
            identityKeySHA256: String(repeating: "a", count: 64),
            bundleVersion: 1,
            signedPreKeyID: 1,
            signedPreKeySHA256: String(repeating: "b", count: 64),
            pqLastResortPreKeyID: 2,
            pqLastResortPreKeySHA256: String(repeating: "c", count: 64)
        )
        fixture.secureMessaging = secureMessaging
        return fixture
    }

    static var communicationPreferences: CommunicationPreferencesDTO {
        decode(
            """
            {
              "version": 4,
              "phone_discoverable": true,
              "direct_message_requests_enabled": true,
              "incoming_calls_enabled": true,
              "messaging_presence_visible": true,
              "updated_at": "2026-08-24T09:40:00Z"
            }
            """
        )
    }

    static var callContacts: [CallableContact] {
        contacts.prefix(4).map {
            CallableContact(
                id: $0.id,
                name: $0.name,
                subtitle: $0.tag.map { "@\($0)" } ?? $0.phone,
                isKitUser: true,
                phoneIdentity: $0.phone,
                source: $0
            )
        }
    }

    static var mobileMoneyNetworks: [MobileMoneyNetworkDTO] {
        decode(
            """
            [
              {"id":"10000000-0000-4000-8000-000000000001","code":"MTN","name":"MTN Mobile Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}},
              {"id":"10000000-0000-4000-8000-000000000002","code":"AIRTEL","name":"Airtel Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}}
            ]
            """
        )
    }

    static var mobileMoneyAccounts: [MobileMoneyAccountDTO] {
        decode(
            """
            [
              {"id":"11000000-0000-4000-8000-000000000001","kind":"own","label":"Demo MTN","network":{"id":"10000000-0000-4000-8000-000000000001","code":"MTN","name":"MTN Mobile Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}},"account_name":"KIT PAY DEMO","phone_number_masked":"+256 70• ••• 000","status":"active"},
              {"id":"11000000-0000-4000-8000-000000000002","kind":"third_party","label":"Amina Demo","network":{"id":"10000000-0000-4000-8000-000000000002","code":"AIRTEL","name":"Airtel Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}},"account_name":"AMINA DEMO","phone_number_masked":"+256 70• ••• 001","status":"active"}
            ]
            """
        )
    }

    static var mobileMoneyOperations: [MobileMoneyOperationDTO] {
        decode(
            """
            [
              {"id":"12000000-0000-4000-8000-000000000001","reference":"MOMO-240826-8124","type":"mobile_money","direction":"inbound","status":"completed","submission_stage":"completed","bank_id":"10000000-0000-4000-8000-000000000001","beneficiary_id":"11000000-0000-4000-8000-000000000001","wallet_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","amount":"150000","currency":{"code":"UGX","scale":"0"},"provider_reference":"MTN884205","wallet_transaction_id":"dddddddd-dddd-4ddd-8ddd-dddddddddd01","created_at":"2026-08-24T08:50:00Z","completed_at":"2026-08-24T08:51:00Z","mobile_money_type":"collection","network":{"id":"10000000-0000-4000-8000-000000000001","code":"MTN","name":"MTN Mobile Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}},"fee_mode":"inclusive","requested_amount":"150000","provider_fee":"500","platform_fee":"0","rounding_adjustment":"0","total_fees":"500","net_amount":"149500"},
              {"id":"12000000-0000-4000-8000-000000000002","reference":"MOMO-230826-7391","type":"mobile_money","direction":"outbound","status":"completed","submission_stage":"completed","bank_id":"10000000-0000-4000-8000-000000000002","beneficiary_id":"11000000-0000-4000-8000-000000000002","wallet_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","amount":"50000","currency":{"code":"UGX","scale":"0"},"provider_reference":"AIR731905","wallet_transaction_id":"dddddddd-dddd-4ddd-8ddd-dddddddddd02","created_at":"2026-08-23T14:20:00Z","completed_at":"2026-08-23T14:21:00Z","mobile_money_type":"payout","network":{"id":"10000000-0000-4000-8000-000000000002","code":"AIRTEL","name":"Airtel Money","currency":{"code":"UGX","scale":"0"},"capabilities":{"collections":true,"payouts":true,"account_verification":true}},"outbound_quote_id":"12000000-0000-4000-8000-000000000012","outbound_pricing":{"fee_mode":"sender_absorbs","recipient_amount":"50000","processing_fee":"500","provider_fee":"500","kit_fee":"0","provider_fee_cap":"500","maximum_provider_total":"50500","customer_debit":"50500","kit_debit":"0","schedule_version":"ug-mobile-money-2026-04-01"}}
            ]
            """
        )
    }

    static var banks: [BankDTO] {
        decode(
            """
            [
              {"id":"13000000-0000-4000-8000-000000000001","code":"01","name":"Stanbic Bank Uganda","country_code":"UG","currency":"UGX","capabilities":{"transfers":true,"account_verification":true}},
              {"id":"13000000-0000-4000-8000-000000000002","code":"02","name":"Centenary Bank","country_code":"UG","currency":"UGX","capabilities":{"transfers":true,"account_verification":true}}
            ]
            """
        )
    }

    static var bankBeneficiaries: [BankBeneficiaryDTO] {
        decode(
            """
            [
              {"id":"14000000-0000-4000-8000-000000000001","kind":"third_party","label":"Amina Demo","bank":{"id":"13000000-0000-4000-8000-000000000001","code":"01","name":"Stanbic Bank Uganda","country_code":"UG","currency":"UGX","capabilities":{"transfers":true,"account_verification":true}},"account_name":"AMINA DEMO","account_number_masked":"•••• 0001","status":"active"},
              {"id":"14000000-0000-4000-8000-000000000002","kind":"third_party","label":"Kampala Supplies Demo","bank":{"id":"13000000-0000-4000-8000-000000000002","code":"02","name":"Centenary Bank","country_code":"UG","currency":"UGX","capabilities":{"transfers":true,"account_verification":true}},"account_name":"KAMPALA SUPPLIES DEMO","account_number_masked":"•••• 0002","status":"active"}
            ]
            """
        )
    }

    static var bankOperations: [BankingOperationDTO] {
        decode(
            """
            [
              {"id":"15000000-0000-4000-8000-000000000001","reference":"BANK-240826-1842","type":"bank_transfer","direction":"outbound","status":"completed","submission_stage":"completed","bank_id":"13000000-0000-4000-8000-000000000001","beneficiary_id":"14000000-0000-4000-8000-000000000001","wallet_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","amount":"275000","currency":{"code":"UGX","scale":"0"},"provider_reference":"STB420184","wallet_transaction_id":"dddddddd-dddd-4ddd-8ddd-dddddddddd03","created_at":"2026-08-24T07:30:00Z","completed_at":"2026-08-24T07:31:00Z"},
              {"id":"15000000-0000-4000-8000-000000000002","reference":"BANK-220826-3390","type":"bank_transfer","direction":"outbound","status":"completed","submission_stage":"completed","bank_id":"13000000-0000-4000-8000-000000000002","beneficiary_id":"14000000-0000-4000-8000-000000000002","wallet_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","amount":"640000","currency":{"code":"UGX","scale":"0"},"provider_reference":"CEN739184","wallet_transaction_id":"dddddddd-dddd-4ddd-8ddd-dddddddddd04","created_at":"2026-08-22T11:05:00Z","completed_at":"2026-08-22T11:06:00Z"}
            ]
            """
        )
    }

    private static let currency = CurrencyDTO(code: "UGX", scale: "0")

    private static var contacts: [WalletContactDTO] {
        [
            contact(aminaID, "Amina Demo", "+256 700 000 001", "amina_demo"),
            contact(brianID, "Brian Sample", "+256 700 000 002", "brian_sample"),
            contact(claireID, "Claire Demo", "+256 700 000 003", "claire_demo"),
            contact(danielID, "Daniel Sample", "+256 700 000 004", "daniel_sample"),
            contact(estherID, "Esther Demo", "+256 700 000 005", "esther_demo"),
            contact(frankID, "Frank Sample", "+256 700 000 006", "frank_sample"),
            contact(graceID, "Grace Demo", "+256 700 000 007", "grace_demo"),
            contact(henryID, "Henry Sample", "+256 700 000 008", "henry_sample"),
        ]
    }

    private static var conversations: [Conversation] {
        let peers = [aminaID, brianID, claireID, danielID, estherID, frankID, graceID, henryID]
        let names = [
            "Amina Demo", "Brian Sample", "Claire Demo", "Daniel Sample",
            "Esther Demo", "Frank Sample", "Grace Demo", "Henry Sample",
        ]
        let identifiers = [
            primaryConversationID,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7",
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8",
        ]
        return zip(zip(identifiers, peers), names).enumerated().map { index, entry in
            Conversation(
                id: entry.0.0,
                title: entry.1,
                participantUserIds: [ownerID, entry.0.1],
                unreadCount: index == 1 ? 2 : (index == 4 ? 1 : 0),
                updatedAt: timestamp("2026-08-24T09:\(String(format: "%02d", 38 - index * 4)):00Z")
            )
        }
    }

    private static var messages: [LocalMessage] {
        let paymentID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let transfer = KitPaymentMessage(
            action: .transfer,
            paymentRequestId: paymentID,
            amountMinor: 75_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: "Market delivery"
        )!.encoded
        let accepted = KitPaymentMessage(
            action: .accepted,
            paymentRequestId: paymentID,
            amountMinor: 75_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: "Market delivery"
        )!.encoded

        var result: [LocalMessage] = [
            message(1, conversation: primaryConversationID, sender: aminaID, body: "Good morning! The market delivery is ready.", minute: 8, outgoing: false),
            message(2, conversation: primaryConversationID, sender: ownerID, body: "Wonderful — please bring it by this afternoon.", minute: 11, outgoing: true),
            message(3, conversation: primaryConversationID, sender: aminaID, body: "Perfect. I included the fresh fruit you asked for 🍍", minute: 14, outgoing: false),
            message(4, conversation: primaryConversationID, sender: ownerID, body: "Thank you! I’ll send the payment right here.", minute: 18, outgoing: true),
            message(5, conversation: primaryConversationID, sender: ownerID, body: transfer, minute: 21, outgoing: true),
            message(6, conversation: primaryConversationID, sender: aminaID, body: accepted, minute: 23, outgoing: false),
            message(7, conversation: primaryConversationID, sender: aminaID, body: "Received safely. Shall we have a quick video call later?", minute: 29, outgoing: false),
            message(8, conversation: primaryConversationID, sender: ownerID, body: "Yes — 6:00 PM works for me.", minute: 33, outgoing: true),
        ]
        let previews = [
            "The project notes look great.",
            "See you at the office tomorrow.",
            "Thanks for the airtime!",
            "Can you send the receipt?",
            "Voice call when you are free?",
            "I’ve accepted the request.",
            "Welcome to the family group.",
        ]
        for index in 1 ..< conversations.count {
            result.append(
                message(
                    20 + index,
                    conversation: conversations[index].id,
                    sender: index == 1 || index == 4 ? conversations[index].participantUserIds[1] : ownerID,
                    body: previews[index - 1],
                    minute: 36 - index * 4,
                    outgoing: !(index == 1 || index == 4)
                )
            )
        }
        return result
    }

    private static var calls: [CallRecord] {
        let people = [
            (aminaID, "Amina Demo", false, "incoming", CallState.completed, 86),
            (brianID, "Brian Sample", true, "outgoing", CallState.completed, 180),
            (claireID, "Claire Demo", false, "incoming", CallState.missed, 0),
            (danielID, "Daniel Sample", true, "incoming", CallState.completed, 322),
            (estherID, "Esther Demo", false, "outgoing", CallState.declined, 0),
            (frankID, "Frank Sample", false, "incoming", CallState.completed, 241),
            (graceID, "Grace Demo", true, "outgoing", CallState.completed, 415),
        ]
        return people.enumerated().map { index, item in
            let start = timestamp("2026-08-\(String(format: "%02d", 24 - index))T0\(9 - min(index, 4)):15:00Z")
            return CallRecord(
                id: "f0000000-0000-4000-8000-00000000000\(index + 1)",
                name: item.1,
                participantUserIds: [ownerID, item.0],
                direction: item.3,
                type: item.2 ? "video" : "voice",
                video: item.2,
                state: item.4,
                startedAt: start,
                endedAt: item.5 > 0 ? start.addingTimeInterval(TimeInterval(item.5)) : start,
                isDeferredAttempt: false,
                conversationId: index == 0 ? primaryConversationID : nil,
                answeredAt: item.5 > 0 ? start.addingTimeInterval(8) : nil
            )
        }
    }

    private static var transactions: [WalletTransaction] {
        [
            transaction(1, amount: "150000", type: "mobile_money", direction: "credit", name: "MTN Mobile Money", note: "Money added", hour: 8),
            transaction(2, amount: "75000", type: "transfer", direction: "debit", name: "Amina Demo", note: "Market delivery", hour: 7),
            transaction(3, amount: "320000", type: "transfer", direction: "credit", name: "Brian Sample", note: "Project contribution", hour: 6),
            transaction(4, amount: "45000", type: "airtime", direction: "debit", name: "Airtime", note: "+256 759 ••• 200", hour: 5),
            transaction(5, amount: "275000", type: "bank_transfer", direction: "debit", name: "Stanbic Bank Uganda", note: "Amina Demo", hour: 4),
            transaction(6, amount: "85000", type: "bill_payment", direction: "debit", name: "NWSC", note: "Water bill", hour: 3),
        ]
    }

    private static func contact(
        _ id: String,
        _ name: String,
        _ phone: String,
        _ tag: String
    ) -> WalletContactDTO {
        WalletContactDTO(
            id: id,
            contactId: "device-\(id.prefix(8))",
            name: name,
            phone: phone,
            isKitUser: true,
            favorite: name == "Amina Demo",
            status: "active",
            tag: tag,
            avatarURL: nil,
            receivingWalletId: nil
        )
    }

    private static func message(
        _ index: Int,
        conversation: String,
        sender: String,
        body: String,
        minute: Int,
        outgoing: Bool
    ) -> LocalMessage {
        let date = timestamp("2026-08-24T09:\(String(format: "%02d", minute)):00Z")
        return LocalMessage(
            id: UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index))!,
            serverMessageId: String(format: "21000000-0000-4000-8000-%012d", index),
            conversationId: conversation,
            senderId: sender,
            body: body,
            createdAt: date,
            sentAt: date,
            state: outgoing ? .read : .received,
            failureReason: nil,
            isOutgoing: outgoing
        )
    }

    private static func transaction(
        _ index: Int,
        amount: String,
        type: String,
        direction: String,
        name: String,
        note: String,
        hour: Int
    ) -> WalletTransaction {
        WalletTransaction(
            id: String(format: "dddddddd-dddd-4ddd-8ddd-%012d", index),
            walletId: walletID,
            reference: String(format: "KIT-240826-%04d", 4100 + index),
            amount: amount,
            currency: currency,
            type: type,
            direction: direction,
            status: "completed",
            counterparty: Counterparty(
                id: nil,
                name: name,
                phone: nil,
                accountNumber: nil
            ),
            note: note,
            occurredAt: "2026-08-24T0\(hour):20:00Z"
        )
    }

    private static func timestamp(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            preconditionFailure("Invalid screenshot fixture timestamp")
        }
        return date
    }

    private static func decode<Value: Decodable>(_ json: String) -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("Invalid screenshot fixture JSON: \(error)")
        }
    }
}
#endif

/// Supplies wall-clock values used only to present dates. Normal app builds retain the device's
/// current clock, calendar, locale, and time zone. The explicitly launched screenshot fixture gets
/// one immutable UTC instant and locale so captured copy does not drift between CI runs.
enum AppPresentationClock {
    static var now: Date {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return AppStoreScreenshotFixture.presentationNow
        }
#endif
        return Date()
    }

    static var calendar: Calendar {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            var value = Calendar(identifier: .gregorian)
            value.locale = fixtureLocale
            value.timeZone = fixtureTimeZone
            return value
        }
#endif
        return .autoupdatingCurrent
    }

    static var locale: Locale {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return fixtureLocale
        }
#endif
        return .autoupdatingCurrent
    }

    static func shortTime(_ date: Date) -> String {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return fixtureString(from: date, dateStyle: .none, timeStyle: .short)
        }
#endif
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func abbreviatedDate(_ date: Date) -> String {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return fixtureString(from: date, dateStyle: .medium, timeStyle: .none)
        }
#endif
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func abbreviatedDateAndShortTime(_ date: Date) -> String {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return fixtureString(from: date, dateStyle: .medium, timeStyle: .short)
        }
#endif
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func numericDate(_ date: Date) -> String {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            return fixtureString(from: date, dateStyle: .short, timeStyle: .none)
        }
#endif
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func abbreviatedWeekday(_ date: Date) -> String {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            let formatter = fixtureFormatter(dateStyle: .none, timeStyle: .none)
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        }
#endif
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

#if DEBUG && APP_STORE_SCREENSHOTS
    private static let fixtureLocale = Locale(identifier: "en_UG")
    private static let fixtureTimeZone = TimeZone(secondsFromGMT: 0)!

    private static func fixtureString(
        from date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> String {
        fixtureFormatter(dateStyle: dateStyle, timeStyle: timeStyle).string(from: date)
    }

    private static func fixtureFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = fixtureLocale
        formatter.timeZone = fixtureTimeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
#endif
}
