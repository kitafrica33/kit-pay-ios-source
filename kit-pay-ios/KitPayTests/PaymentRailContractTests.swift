import CryptoKit
import XCTest
@testable import KitPay

final class PaymentRailContractTests: XCTestCase {
    func testMobileMoneyAmountIsCanonicalWholeUnitAtCurrencyScale() {
        XCTAssertEqual(MobileMoneyAmount.wholeUnitAPIAmount("001000", scale: 2), "1000.00")
        XCTAssertEqual(MobileMoneyAmount.wholeUnitAPIAmount("1", scale: 0), "1")
        XCTAssertNil(MobileMoneyAmount.wholeUnitAPIAmount("0", scale: 2))
        XCTAssertNil(MobileMoneyAmount.wholeUnitAPIAmount("1.5", scale: 2))
        XCTAssertNil(MobileMoneyAmount.wholeUnitAPIAmount("-1", scale: 2))
    }

    func testMobileMoneyCollectionAmountRoundsSilentlyToNearestWholeUnit() throws {
        XCTAssertEqual(MobileMoneyAmount.roundedCollectionAPIAmount("500.49", scale: 2), "500.00")
        XCTAssertEqual(MobileMoneyAmount.roundedCollectionAPIAmount("500.50", scale: 2), "501.00")
        XCTAssertEqual(MobileMoneyAmount.roundedCollectionAPIAmount("1,250.75", scale: 0), "1251")
        XCTAssertNil(MobileMoneyAmount.roundedCollectionAPIAmount("0.49", scale: 2))
        XCTAssertNil(MobileMoneyAmount.roundedCollectionAPIAmount("-500.50", scale: 2))
        XCTAssertNil(MobileMoneyAmount.roundedCollectionAPIAmount("not an amount", scale: 2))
        XCTAssertTrue(MobileMoneyAmount.amountsMatch("501", "501.00"))
        XCTAssertFalse(MobileMoneyAmount.amountsMatch("501", "501.01"))

        let amount = try XCTUnwrap(MobileMoneyAmount.roundedCollectionAPIAmount("499.50", scale: 2))
        let request = CreateMobileMoneyCollectionQuoteRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: amount,
            feeMode: .inclusive
        )
        XCTAssertEqual(try jsonObject(request)["amount"] as? String, "500.00")
    }

    func testPayoutUIRequiresAtLeastOneExplicitlyEnabledNetwork() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let collectionOnly = MobileMoneyNetworkDTO(
            id: "network-mtn",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: currency,
            capabilities: [
                "collections": true,
                "payouts": false,
                "account_verification": true,
            ]
        )
        let omittedPayout = MobileMoneyNetworkDTO(
            id: "network-airtel",
            code: "AIRTEL",
            name: "Airtel Money",
            currency: currency,
            capabilities: [
                "collections": true,
                "account_verification": true,
            ]
        )
        let payoutEnabled = MobileMoneyNetworkDTO(
            id: "network-enabled",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: currency,
            capabilities: ["payouts": true]
        )

        XCTAssertFalse([MobileMoneyNetworkDTO]().supportsMobileMoneyPayouts)
        XCTAssertFalse([collectionOnly, omittedPayout].supportsMobileMoneyPayouts)
        XCTAssertTrue([collectionOnly, payoutEnabled].supportsMobileMoneyPayouts)

        let ambiguous = MobileMoneyNetworkDTO(
            id: "network-ambiguous",
            code: "MTN",
            name: "Ambiguous shared-store row",
            currency: currency,
            capabilities: ["payouts": true, "transfers": true]
        )
        XCTAssertFalse([ambiguous].supportsMobileMoneyPayouts)
    }

    func testSendAndWithdrawUsePayoutContractButKeepAccountOwnershipDistinct() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let network = MobileMoneyNetworkDTO(
            id: "network-mtn",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: currency,
            capabilities: [
                "collections": true,
                "payouts": true,
                "account_verification": true,
            ]
        )
        let own = MobileMoneyAccountDTO(
            id: "own-account",
            kind: "own",
            label: "My MTN",
            network: network,
            accountName: "Kit customer",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )
        let recipient = MobileMoneyAccountDTO(
            id: "recipient-account",
            kind: "third_party",
            label: "ExampleContact",
            network: network,
            accountName: "ExampleContact",
            phoneNumberMasked: "+256 7•• ••• 001",
            status: "active"
        )

        XCTAssertEqual(MobileMoneyFlow.send.action, .payout)
        XCTAssertEqual(MobileMoneyFlow.withdraw.action, .payout)
        XCTAssertEqual(MobileMoneyFlow.addMoney.action, .collection)
        XCTAssertEqual(MobileMoneyFlow.send.action.endpointComponent, "payouts")
        XCTAssertEqual(MobileMoneyFlow.withdraw.action.purpose, "mobile_money_payout")
        XCTAssertTrue(own.isEligible(for: .addMoney))
        XCTAssertTrue(own.isEligible(for: .withdraw))
        XCTAssertFalse(own.isEligible(for: .send))
        XCTAssertTrue(recipient.isEligible(for: .send))
        XCTAssertFalse(recipient.isEligible(for: .withdraw))
        XCTAssertFalse(recipient.isEligible(for: .addMoney))
    }

    func testSavedAccountRailPolicyKeepsBankDestinationsOffTheMobileMoneySurface() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let mobileNetwork = MobileMoneyNetworkDTO(
            id: "network-mtn",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: currency,
            capabilities: ["collections": true, "payouts": true, "account_verification": true]
        )
        let bankAsNetwork = MobileMoneyNetworkDTO(
            id: "bank-stanbic",
            code: "040147",
            name: "Stanbic Bank Uganda",
            currency: currency,
            capabilities: ["account_verification": true, "transfers": true]
        )
        let mixedRailSignals = MobileMoneyNetworkDTO(
            id: "network-ambiguous",
            code: "AIRTEL",
            name: "Airtel Money",
            currency: currency,
            capabilities: ["payouts": true, "transfers": true]
        )
        let missingCode = MobileMoneyNetworkDTO(
            id: "network-unlabelled",
            code: " ",
            name: "Unlabelled",
            currency: currency,
            capabilities: ["collections": true]
        )

        XCTAssertTrue(
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(mobileNetwork)
        )
        XCTAssertFalse(
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(bankAsNetwork)
        )
        XCTAssertFalse(
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(mixedRailSignals)
        )
        XCTAssertFalse(
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(missingCode)
        )

        let mobileAccount = MobileMoneyAccountDTO(
            id: "mobile-account",
            kind: "own",
            label: "My MTN",
            network: mobileNetwork,
            accountName: "Kit Customer",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )
        let bankAccount = MobileMoneyAccountDTO(
            id: "bank-account",
            kind: "third_party",
            label: "Bank beneficiary",
            network: bankAsNetwork,
            accountName: "EXAMPLE CONTACT",
            phoneNumberMasked: "••••5678",
            status: "active"
        )
        let ambiguousPayoutAccount = MobileMoneyAccountDTO(
            id: "ambiguous-payout-account",
            kind: "third_party",
            label: "Ambiguous payout",
            network: mixedRailSignals,
            accountName: "Ambiguous Recipient",
            phoneNumberMasked: "+256 7•• ••• 003",
            status: "active"
        )
        let ambiguousOwnAccount = MobileMoneyAccountDTO(
            id: "ambiguous-own-account",
            kind: "own",
            label: "Ambiguous own account",
            network: mixedRailSignals,
            accountName: "Kit Customer",
            phoneNumberMasked: "+256 7•• ••• 004",
            status: "active"
        )

        XCTAssertEqual(
            MobileMoneySavedAccountRailPolicy.mobileMoneyAccounts(
                [bankAccount, mobileAccount]
            ).map(\.id),
            ["mobile-account"]
        )
        XCTAssertFalse(ambiguousPayoutAccount.isPayoutCapable)
        XCTAssertTrue(
            MobileMoneyPayoutSavedAccountPolicy.eligibleAccounts(
                from: [ambiguousPayoutAccount],
                ownership: .someoneElse
            ).isEmpty
        )
        XCTAssertFalse(ambiguousOwnAccount.isEligible(for: .addMoney))
        XCTAssertFalse(MobileMoneySavedAccountActionPolicy.canCollect(from: ambiguousOwnAccount))
        XCTAssertNil(MobileMoneySavedAccountActionPolicy.payoutFlow(for: ambiguousOwnAccount))
    }

    func testSavedAccountOwnershipUsesOnlyTheTwoBackendClassifications() {
        XCTAssertEqual(MobileMoneySavedAccountOwnership(kind: " own "), .mine)
        XCTAssertEqual(MobileMoneySavedAccountOwnership(kind: "THIRD_PARTY"), .beneficiary)
        XCTAssertEqual(MobileMoneySavedAccountOwnership.mine.title, "Mine")
        XCTAssertEqual(MobileMoneySavedAccountOwnership.beneficiary.title, "Beneficiary")
        XCTAssertNil(MobileMoneySavedAccountOwnership(kind: "owner"))
        XCTAssertNil(MobileMoneySavedAccountOwnership(kind: ""))
    }

    func testSavedAccountDetailAcceptsOnlyItsExactBoundOperations() {
        let accountID = "33333333-3333-4333-8333-333333333333"
        let otherAccountID = "44444444-4444-4444-8444-444444444444"
        let network = MobileMoneyNetworkDTO(
            id: "22222222-2222-4222-8222-222222222222",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["collections": true, "payouts": true]
        )
        let account = MobileMoneyAccountDTO(
            id: accountID,
            kind: "own",
            label: "My MTN",
            network: network,
            accountName: "KIT CUSTOMER",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )
        let exact = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            beneficiaryId: accountID
        )
        let unrelated = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            beneficiaryId: otherAccountID
        )

        XCTAssertTrue(MobileMoneySavedAccountContract.isValidDetail(
            MobileMoneyAccountDetailDTO(account: account, recentOperations: [exact]),
            expectedAccount: account
        ))
        XCTAssertFalse(MobileMoneySavedAccountContract.isValidDetail(
            MobileMoneyAccountDetailDTO(account: account, recentOperations: [exact, unrelated]),
            expectedAccount: account
        ))
        XCTAssertEqual(
            MobileMoneySavedAccountActivity.recentOperations(
                for: accountID,
                from: [unrelated, exact]
            ).map(\.id),
            [exact.id]
        )
        XCTAssertTrue(MobileMoneySavedAccountActivity.recentOperations(
            for: "not-a-uuid",
            from: [exact]
        ).isEmpty)
    }

    func testSavedAccountMutationResponsesMustMatchTheExactDestination() throws {
        let network = MobileMoneyNetworkDTO(
            id: "22222222-2222-4222-8222-222222222222",
            code: "AIRTEL",
            name: "Airtel Money",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["payouts": true]
        )
        let account = MobileMoneyAccountDTO(
            id: "33333333-3333-4333-8333-333333333333",
            kind: "own",
            label: "My Airtel",
            network: network,
            accountName: "KIT CUSTOMER",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )
        let updated = MobileMoneyAccountDTO(
            id: account.id,
            kind: "third_party",
            label: account.label,
            network: network,
            accountName: account.accountName,
            phoneNumberMasked: account.phoneNumberMasked,
            status: "active"
        )
        let wrongNumber = MobileMoneyAccountDTO(
            id: account.id,
            kind: "third_party",
            label: account.label,
            network: network,
            accountName: account.accountName,
            phoneNumberMasked: "+256 7•• ••• 999",
            status: "active"
        )

        XCTAssertTrue(MobileMoneySavedAccountContract.isValidOwnershipUpdate(
            updated,
            expectedAccount: account,
            ownership: .beneficiary
        ))
        XCTAssertFalse(MobileMoneySavedAccountContract.isValidOwnershipUpdate(
            wrongNumber,
            expectedAccount: account,
            ownership: .beneficiary
        ))
        XCTAssertTrue(MobileMoneySavedAccountContract.isValidDeletion(
            MobileMoneyAccountDeletionDTO(id: account.id, deleted: true),
            expectedAccountID: account.id.uppercased()
        ))
        XCTAssertFalse(MobileMoneySavedAccountContract.isValidDeletion(
            MobileMoneyAccountDeletionDTO(id: account.id, deleted: false),
            expectedAccountID: account.id
        ))
        XCTAssertEqual(
            try jsonObject(UpdateMobileMoneyAccountRequest(kind: "third_party"))["kind"] as? String,
            "third_party"
        )
    }

    func testOutboundFlowFailsClosedForInactiveOrNonPayoutAccounts() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let collectionOnly = MobileMoneyNetworkDTO(
            id: "network-airtel",
            code: "AIRTEL",
            name: "Airtel Money",
            currency: currency,
            capabilities: ["collections": true, "payouts": false]
        )
        let disabledRecipient = MobileMoneyAccountDTO(
            id: "recipient-account",
            kind: "third_party",
            label: "Recipient",
            network: collectionOnly,
            accountName: "Recipient",
            phoneNumberMasked: "+256 7•• ••• 001",
            status: "active"
        )
        let inactiveOwn = MobileMoneyAccountDTO(
            id: "own-account",
            kind: "own",
            label: "My Airtel",
            network: collectionOnly,
            accountName: "Kit customer",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "inactive"
        )
        let unknownKind = MobileMoneyAccountDTO(
            id: "unknown-account",
            kind: "legacy",
            label: "Unknown",
            network: MobileMoneyNetworkDTO(
                id: "network-mtn",
                code: "MTN",
                name: "MTN Mobile Money",
                currency: currency,
                capabilities: ["payouts": true]
            ),
            accountName: "Unknown",
            phoneNumberMasked: "+256 7•• ••• 999",
            status: "active"
        )

        XCTAssertFalse(disabledRecipient.isEligible(for: .send))
        XCTAssertFalse(inactiveOwn.isEligible(for: .withdraw))
        XCTAssertFalse(inactiveOwn.isEligible(for: .addMoney))
        XCTAssertFalse(unknownKind.isEligible(for: .send))
    }

    func testUgandaMobileMoneyPhoneFormattingRemovesZeroAndSendsCanonicalDigits() {
        XCTAssertEqual(UgandaMobileMoneyPhone.nationalDigits(from: "0750000002"), "750000002")
        XCTAssertEqual(UgandaMobileMoneyPhone.spacedNationalDigits(from: "0750000002"), "750 000 002")
        XCTAssertEqual(UgandaMobileMoneyPhone.apiValue(from: "+256 750 000 002"), "256750000002")
        XCTAssertEqual(UgandaMobileMoneyPhone.apiValue(from: "750000002"), "256750000002")
        XCTAssertEqual(UgandaMobileMoneyPhone.apiValue(from: "00256 0750 000 002"), "256750000002")
        XCTAssertEqual(UgandaMobileMoneyPhone.apiValue(from: "٠٧٥٠٠٠٠٠٠٢"), "256750000002")
        XCTAssertEqual(UgandaMobileMoneyPhone.e164Value(from: "0750000002"), "+256750000002")
        XCTAssertEqual(
            UgandaMobileMoneyPhone.internationalDisplayValue(from: "+256750000002"),
            "+256 750 000 002"
        )
        XCTAssertNil(UgandaMobileMoneyPhone.apiValue(from: "650000002"))
        XCTAssertNil(UgandaMobileMoneyPhone.apiValue(from: "07500000021"))
    }

    func testPayoutLookupStartsOnlyForAFullCanonicalMTNOrAirtelNumber() throws {
        XCTAssertNil(MobileMoneyPayoutLookupRequest(
            networkCode: "MTN",
            rawPhoneNumber: "750 000 02",
            ownership: .someoneElse
        ))
        XCTAssertNil(MobileMoneyPayoutLookupRequest(
            networkCode: "UNKNOWN",
            rawPhoneNumber: "0750 000 002",
            ownership: .someoneElse
        ))

        let mtn = try XCTUnwrap(MobileMoneyPayoutLookupRequest(
            networkCode: "mtn",
            rawPhoneNumber: "+256 750 000 002",
            ownership: .myself
        ))
        let airtel = try XCTUnwrap(MobileMoneyPayoutLookupRequest(
            networkCode: "airtel",
            rawPhoneNumber: "0700 000 001",
            ownership: .someoneElse
        ))

        XCTAssertEqual(mtn.networkCode, "MTN")
        XCTAssertEqual(mtn.phoneNumber, "256750000002")
        XCTAssertEqual(mtn.ownership.accountKind, "own")
        XCTAssertEqual(airtel.networkCode, "AIRTEL")
        XCTAssertEqual(airtel.phoneNumber, "256700000001")
        XCTAssertEqual(airtel.ownership.accountKind, "third_party")
    }

    func testPayoutLookupGenerationRejectsStaleNumberAndOwnershipResults() throws {
        let first = try XCTUnwrap(MobileMoneyPayoutLookupRequest(
            networkCode: "MTN",
            rawPhoneNumber: "0750 000 002",
            ownership: .myself
        ))
        let second = try XCTUnwrap(MobileMoneyPayoutLookupRequest(
            networkCode: "AIRTEL",
            rawPhoneNumber: "0700 000 001",
            ownership: .someoneElse
        ))
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        var generation = MobileMoneyLookupGeneration()

        _ = generation.begin(first, id: firstID)
        XCTAssertTrue(generation.accepts(firstID, request: first))
        _ = generation.begin(second, id: secondID)
        XCTAssertFalse(generation.accepts(firstID, request: first))
        XCTAssertFalse(generation.accepts(firstID, request: second))
        XCTAssertTrue(generation.accepts(secondID, request: second))
        generation.invalidate()
        XCTAssertFalse(generation.accepts(secondID, request: second))
    }

    func testDirectVerifiedBeneficiarySupportsPayoutButNotCollection() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let network = MobileMoneyNetworkDTO(
            id: "network-mtn",
            code: "MTN",
            name: "MTN Mobile Money",
            currency: currency,
            capabilities: ["collections": true, "payouts": true]
        )
        let existingThirdParty = MobileMoneyAccountDTO(
            id: "existing-account",
            kind: "third_party",
            label: "Verified number",
            network: network,
            accountName: "Verified Customer",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )

        XCTAssertTrue(existingThirdParty.isPayoutCapable)
        XCTAssertFalse(existingThirdParty.hasPreferredPayoutOwnership(.myself))
        XCTAssertTrue(existingThirdParty.hasPreferredPayoutOwnership(.someoneElse))
        XCTAssertFalse(existingThirdParty.isEligible(for: .addMoney))
        XCTAssertEqual(MobileMoneyFlow.send.defaultPayoutOwnership, .someoneElse)
        XCTAssertEqual(MobileMoneyFlow.withdraw.defaultPayoutOwnership, .myself)
    }

    func testSavedPayoutSelectionBindsOnlyTheMatchingOwnerAndVerifiedIdentity() throws {
        let network = MobileMoneyNetworkDTO(
            id: "network-airtel",
            code: "AIRTEL",
            name: "Airtel",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["payouts": true]
        )
        let beneficiary = MobileMoneyAccountDTO(
            id: "beneficiary-account",
            kind: "third_party",
            label: "ExampleContact",
            network: network,
            accountName: "Example Contact",
            phoneNumberMasked: "+256 7•• ••• 001",
            status: "active"
        )
        let saved = MobileMoneyPayoutLookupState.saved(.someoneElse, beneficiary)

        XCTAssertEqual(MobileMoneyPayoutRecipientSource.savedAccount.title, "Saved")
        XCTAssertEqual(MobileMoneyPayoutRecipientSource.newNumber.title, "New number")
        XCTAssertEqual(saved.account(for: .someoneElse), beneficiary)
        XCTAssertNil(saved.account(for: .myself))
        XCTAssertTrue(beneficiary.isPayoutCapable)
        XCTAssertTrue(beneficiary.hasConfirmedPayoutIdentity)
        XCTAssertTrue(beneficiary.hasSamePayoutIdentity(as: beneficiary))

        let changedIdentity = MobileMoneyAccountDTO(
            id: beneficiary.id,
            kind: beneficiary.kind,
            label: beneficiary.label,
            network: network,
            accountName: "Different Recipient",
            phoneNumberMasked: beneficiary.phoneNumberMasked,
            status: beneficiary.status
        )
        XCTAssertFalse(beneficiary.hasSamePayoutIdentity(as: changedIdentity))
    }

    func testSavedPayoutSelectionRejectsUnsupportedNetworkAndMissingAccountName() {
        let unsupportedNetwork = MobileMoneyNetworkDTO(
            id: "network-unknown",
            code: "UNKNOWN",
            name: "Unknown",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["payouts": true]
        )
        let account = MobileMoneyAccountDTO(
            id: "unknown-account",
            kind: "third_party",
            label: "Unverified recipient",
            network: unsupportedNetwork,
            accountName: " ",
            phoneNumberMasked: "+256 7•• ••• 999",
            status: "active"
        )

        XCTAssertFalse(account.isPayoutCapable)
        XCTAssertFalse(account.hasConfirmedPayoutIdentity)
    }

    func testSavedAccountActionsRespectOwnershipAndNetworkDirection() {
        let network = MobileMoneyNetworkDTO(
            id: "network-mtn",
            code: "MTN",
            name: "MTN",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["collections": true, "payouts": true]
        )
        let mine = MobileMoneyAccountDTO(
            id: "mine",
            kind: "own",
            label: "My MTN",
            network: network,
            accountName: "Kit Customer",
            phoneNumberMasked: "+256 7•• ••• 002",
            status: "active"
        )
        let beneficiary = MobileMoneyAccountDTO(
            id: "beneficiary",
            kind: "third_party",
            label: "ExampleContact",
            network: network,
            accountName: "Example Contact",
            phoneNumberMasked: "+256 7•• ••• 001",
            status: "active"
        )

        XCTAssertTrue(MobileMoneySavedAccountActionPolicy.canCollect(from: mine))
        XCTAssertEqual(MobileMoneySavedAccountActionPolicy.payoutFlow(for: mine), .withdraw)
        XCTAssertFalse(MobileMoneySavedAccountActionPolicy.canCollect(from: beneficiary))
        XCTAssertEqual(MobileMoneySavedAccountActionPolicy.payoutFlow(for: beneficiary), .send)
        XCTAssertEqual(
            MobileMoneyPayoutSavedAccountPolicy.eligibleAccounts(
                from: [mine, beneficiary],
                ownership: .someoneElse
            ).map(\.id),
            [beneficiary.id]
        )
    }

    func testMobileMoneyHistoryUsesExactWalletTransactionIdentityWhenAvailable() throws {
        let pricing = MobileMoneyOutboundPricingDTO(
            feeMode: .senderAbsorbs,
            recipientAmount: "500.00",
            processingFee: "150.00",
            totalFees: "150.00",
            pricingScope: CustomerPricingContract.scope,
            customerDebit: "650.00"
        )
        let operation = mobileMoneyOperation(
            status: "succeeded",
            type: "payout",
            failureCode: "",
            walletTransactionId: "wallet-transaction-exact",
            outboundPricing: pricing
        )
        let decoy = WalletTransaction(
            id: "wallet-transaction-decoy",
            walletId: operation.walletId,
            reference: operation.reference,
            amount: "999.00",
            totals: CustomerTransactionTotals(added: "0", deducted: "999.00"),
            currency: operation.currency,
            type: "internal_transfer",
            direction: "debit",
            status: "completed",
            counterparty: nil,
            note: nil,
            occurredAt: "2026-08-19T12:00:00Z"
        )
        let exact = WalletTransaction(
            id: "wallet-transaction-exact",
            walletId: operation.walletId,
            reference: "LEDGER-REFERENCE",
            amount: "650.00",
            totals: CustomerTransactionTotals(added: "0", deducted: "650.00"),
            currency: operation.currency,
            type: "bank_withdrawal",
            direction: "debit",
            status: "completed",
            counterparty: nil,
            note: nil,
            occurredAt: "2026-08-19T12:00:10Z"
        )

        let presented = try XCTUnwrap(MobileMoneyTransactionPresentation.transaction(
            for: operation,
            accounts: [],
            walletTransactions: [decoy, exact]
        ))

        XCTAssertEqual(presented, exact)
        XCTAssertNotEqual(presented, decoy)

        let wrongAmountForExactID = WalletTransaction(
            id: exact.id,
            walletId: exact.walletId,
            reference: exact.reference,
            amount: "651.00",
            totals: CustomerTransactionTotals(added: "0", deducted: "651.00"),
            currency: exact.currency,
            type: exact.type,
            direction: exact.direction,
            status: exact.status,
            counterparty: nil,
            note: nil,
            occurredAt: exact.occurredAt
        )
        XCTAssertNil(MobileMoneyTransactionPresentation.transaction(
            for: operation,
            accounts: [],
            walletTransactions: [wrongAmountForExactID]
        ))
    }

    func testPendingMobileMoneyHistoryUsesStableOperationBoundTransactionFallback() throws {
        let accountID = "33333333-3333-4333-8333-333333333333"
        let network = MobileMoneyNetworkDTO(
            id: "network-airtel",
            code: "AIRTEL",
            name: "Airtel",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            capabilities: ["payouts": true]
        )
        let beneficiary = MobileMoneyAccountDTO(
            id: accountID,
            kind: "third_party",
            label: "ExampleContact",
            network: network,
            accountName: "Example Contact",
            phoneNumberMasked: "+256 7•• ••• 001",
            status: "active"
        )
        let pricing = MobileMoneyOutboundPricingDTO(
            feeMode: .senderAbsorbs,
            recipientAmount: "500.00",
            processingFee: "150.00",
            totalFees: "150.00",
            pricingScope: CustomerPricingContract.scope,
            customerDebit: "650.00"
        )
        let operation = mobileMoneyOperation(
            status: "processing",
            type: "payout",
            failureCode: "",
            beneficiaryId: accountID,
            outboundPricing: pricing
        )

        let presented = try XCTUnwrap(MobileMoneyTransactionPresentation.transaction(
            for: operation,
            accounts: [beneficiary],
            walletTransactions: []
        ))

        XCTAssertEqual(presented.id, "mobile-money-operation:\(operation.id)")
        XCTAssertEqual(presented.walletId, operation.walletId)
        XCTAssertEqual(presented.reference, operation.reference)
        XCTAssertEqual(presented.amount, "650.00")
        XCTAssertEqual(presented.totals?.added, "0")
        XCTAssertEqual(presented.totals?.deducted, "650.00")
        XCTAssertEqual(presented.type, "bank_withdrawal")
        XCTAssertTrue(CustomerTransactionPresentationPolicy.isCustomerVisible(presented))
        XCTAssertEqual(presented.direction, "debit")
        XCTAssertEqual(presented.counterparty?.id, beneficiary.id)
        XCTAssertEqual(presented.counterparty?.name, beneficiary.accountName)

        let unsafeScope = mobileMoneyOperation(
            status: "processing",
            type: "payout",
            failureCode: "",
            beneficiaryId: accountID,
            outboundPricing: pricing,
            pricingScope: "institutional_split"
        )
        XCTAssertNil(unsafeScope.customerTransactionFee)
        XCTAssertNil(MobileMoneyTransactionPresentation.transaction(
            for: unsafeScope,
            accounts: [beneficiary],
            walletTransactions: []
        ))
    }

    func testMobileMoneyHistoryRejectsInternalAndUnverifiedOperationShapes() {
        let safe = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            amount: "517.00",
            totalFees: "17.00",
            netAmount: "500.00",
            pricingScope: CustomerPricingContract.scope
        )
        XCTAssertTrue(MobileMoneyOperationPresentationPolicy.isCustomerVisible(safe))

        let internalType = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            operationType: "operator_provider_fee_funding",
            amount: "517.00",
            totalFees: "17.00",
            netAmount: "500.00",
            pricingScope: CustomerPricingContract.scope
        )
        let wrongDirection = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            direction: "outbound",
            amount: "517.00",
            totalFees: "17.00",
            netAmount: "500.00",
            pricingScope: CustomerPricingContract.scope
        )
        let principalOnlyLegacy = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: "",
            amount: "500.00"
        )

        for operation in [internalType, wrongDirection, principalOnlyLegacy] {
            XCTAssertFalse(MobileMoneyOperationPresentationPolicy.isCustomerVisible(operation))
            XCTAssertNil(MobileMoneyTransactionPresentation.transaction(
                for: operation,
                accounts: [],
                walletTransactions: []
            ))
        }
        XCTAssertEqual(
            MobileMoneyOperationPresentationPolicy.customerVisibleOperations(
                [internalType, safe, wrongDirection, principalOnlyLegacy]
            ).map(\.id),
            [safe.id]
        )
    }

    private let unitedStates = Locale(identifier: "en_US")
    private let uganda = Locale(identifier: "en_UG")
    /// Comma decimal separator, period grouping separator.
    private let germany = Locale(identifier: "de_DE")
    /// Comma decimal separator, non-breaking-space grouping separator.
    private let france = Locale(identifier: "fr_FR")

    /// Every amount a customer reads is grouped. A wallet balance used to render as
    /// `UGX 1250000`, which is unreadable at a glance and easy to misjudge by a factor of ten.
    func testDisplayedAmountsAreGrouped() {
        XCTAssertEqual(
            KitMoney.formatted("1250000", code: "UGX", scale: 0, locale: unitedStates),
            "UGX 1,250,000"
        )
        XCTAssertEqual(
            KitMoney.formatted("1234567.89", code: "USD", scale: 2, locale: unitedStates),
            "USD 1,234,567.89"
        )
        // A blank or missing amount reads as zero rather than as an empty currency code.
        XCTAssertEqual(
            KitMoney.formatted("", code: "UGX", scale: 0, locale: unitedStates),
            "UGX 0"
        )
    }

    /// Read-only money is intentionally stable: input accepts the keyboard locale, but every
    /// settled amount uses comma grouping and a `.` decimal mark.
    func testDisplayedAmountsUseStableSeparatorsAcrossInputLocales() {
        XCTAssertEqual(
            KitMoney.amount("1234567.89", scale: 2, locale: germany),
            "1,234,567.89"
        )
        XCTAssertEqual(
            KitMoney.amount("1234567.89", scale: 2, locale: france),
            "1,234,567.89"
        )
        XCTAssertEqual(
            KitMoney.amount("1234567.89", scale: 2, locale: uganda),
            "1,234,567.89"
        )
    }

    func testCommittedMoneyNeverForcesZeroFractionDigits() {
        XCTAssertEqual(
            KitMoney.amount("1856.84", scale: 2, locale: unitedStates),
            "1,856.84"
        )
        XCTAssertEqual(
            KitMoney.amount("1768.80", scale: 2, locale: unitedStates),
            "1,768.8"
        )
        XCTAssertEqual(
            KitMoney.amount("1000.00", scale: 2, locale: unitedStates),
            "1,000"
        )
    }

    /// Minor units convert in integer arithmetic; `Double` loses whole minor units at this size.
    func testMinorUnitsRenderWithoutFloatingPoint() {
        XCTAssertEqual(KitMoney.decimal(minorUnits: 123_456_789 as Int64, scale: 2), "1234567.89")
        XCTAssertEqual(KitMoney.decimal(minorUnits: 7 as Int64, scale: 2), "0.07")
        XCTAssertEqual(KitMoney.decimal(minorUnits: 75_000 as Int64, scale: 0), "75000")
        XCTAssertEqual(
            KitMoney.formatted(
                minorUnits: 123_456_789 as Int64,
                code: "USD",
                scale: 2,
                locale: unitedStates
            ),
            "USD 1,234,567.89"
        )
    }

    /// Ledger rows carry direction in the sign, using a true minus so digits stay aligned.
    func testLedgerRowsAreSignedAndGrouped() {
        let currency = CurrencyDTO(code: "UGX", scale: "0")
        XCTAssertEqual(
            KitMoney.signed("1250000", currency: currency, direction: "credit", locale: unitedStates),
            "+UGX 1,250,000"
        )
        XCTAssertEqual(
            KitMoney.signed("1250000", currency: currency, direction: "debit", locale: unitedStates),
            "\u{2212}UGX 1,250,000"
        )
        XCTAssertEqual(
            KitMoney.signed("1250000", currency: currency, direction: "hold", locale: unitedStates),
            "UGX 1,250,000"
        )
    }

    func testCustomerHistoryUsesCombinedTotalsWithoutExposingAccountingLegs() throws {
        let transaction: WalletTransaction = try decode(
            """
            {
              "id":"11111111-1111-4111-8111-111111111111",
              "wallet_id":"22222222-2222-4222-8222-222222222222",
              "reference":"KWB-CUSTOMER-TRANSFER",
              "amount":"56000.00",
              "totals":{"added":"0.00","deducted":"56000.00"},
              "currency":{"code":"UGX","scale":"2"},
              "type":"bank_transfer",
              "direction":" DEBIT ",
              "status":"completed",
              "counterparty":null,
              "note":null,
              "claim":null,
              "occurred_at":"2026-08-31T12:00:00Z"
            }
            """
        )

        XCTAssertEqual(transaction.customerAmountAdded, "0.00")
        XCTAssertEqual(transaction.customerAmountDeducted, "56000.00")
        XCTAssertEqual(transaction.customerImpactLabel, "Money Deducted")
        XCTAssertEqual(transaction.customerImpactAmount, "56000.00")
        XCTAssertTrue(CustomerTransactionPresentationPolicy.isCustomerVisible(transaction))

        let receipt = try XCTUnwrap(
            KitReceiptContent.from(transaction: transaction, senderName: "Kit Customer")
        )
        XCTAssertEqual(receipt.headlineAmount, "UGX 56,000")
        XCTAssertEqual(receipt.directionLine, "Money deducted")
        XCTAssertEqual(
            receipt.rows.first(where: { $0.label == "Money Deducted" })?.value,
            "UGX 56,000"
        )
        XCTAssertNil(receipt.rows.first(where: { $0.label == "Wallet" }))
        XCTAssertFalse(receipt.rows.contains(where: {
            $0.value == "22222222-2222-4222-8222-222222222222"
        }))
        XCTAssertFalse(receipt.shareMessage.contains("Kit Pay user"))

        let internalEntry = WalletTransaction(
            id: transaction.id,
            walletId: transaction.walletId,
            reference: transaction.reference,
            amount: transaction.amount,
            totals: transaction.totals,
            currency: transaction.currency,
            type: "institutional_commission",
            direction: transaction.direction,
            status: transaction.status,
            counterparty: transaction.counterparty,
            note: transaction.note,
            claim: transaction.claim,
            occurredAt: transaction.occurredAt
        )
        XCTAssertNil(
            KitReceiptContent.from(transaction: internalEntry, senderName: "Kit Customer")
        )
    }

    func testLegacyCustomerHistoryAndReceiptFailClosedWithoutCombinedTotals() throws {
        let transaction: WalletTransaction = try decode(
            """
            {
              "id":"11111111-1111-4111-8111-111111111112",
              "wallet_id":"22222222-2222-4222-8222-222222222222",
              "reference":"LEGACY-CREDIT",
              "amount":"1000.00",
              "currency":{"code":"UGX","scale":"2"},
              "type":"bank_deposit",
              "direction":"credit",
              "status":"completed",
              "counterparty":null,
              "note":null,
              "claim":null,
              "occurred_at":"2026-08-31T12:00:00Z"
            }
            """
        )

        XCTAssertNil(transaction.totals)
        XCTAssertEqual(transaction.customerAmountAdded, "0")
        XCTAssertEqual(transaction.customerAmountDeducted, "0")
        XCTAssertEqual(transaction.customerImpactLabel, "Money Added")
        XCTAssertFalse(CustomerTransactionPresentationPolicy.isCustomerVisible(transaction))
        XCTAssertNil(
            KitReceiptContent.from(transaction: transaction, senderName: "Kit Customer")
        )
    }

    func testAmountInputFormattingAddsCommasWithoutChangingRawValue() {
        XCTAssertEqual(PaymentInputFormatting.normalizedWholeInput("1,234,567"), "1234567")
        XCTAssertEqual(
            PaymentInputFormatting.groupedWholeInput("1234567", locale: unitedStates),
            "1,234,567"
        )
        XCTAssertEqual(PaymentInputFormatting.normalizedWholeInput("١٬٢٣٤٬٥٦٧"), "1234567")
        XCTAssertEqual(
            PaymentInputFormatting.normalizedDecimalInput(
                "1,234.50",
                maximumFractionDigits: 2,
                locale: unitedStates
            ),
            "1234.50"
        )
        XCTAssertEqual(
            PaymentInputFormatting.groupedDecimalInput(
                "1234.50",
                maximumFractionDigits: 2,
                locale: unitedStates
            ),
            "1,234.50"
        )
    }

    func testLiveAmountEditingGroupsWithoutMovingTheCaretToTheEnd() throws {
        let appended = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "999",
            range: NSRange(location: 3, length: 0),
            replacement: "9",
            currentSelection: NSRange(location: 3, length: 0),
            mode: .whole,
            locale: unitedStates
        ))
        XCTAssertEqual(appended.editingCanonicalValue, "9999")
        XCTAssertEqual(appended.committedCanonicalValue, "9999")
        XCTAssertEqual(appended.displayedValue, "9,999")
        XCTAssertEqual(appended.caretUTF16Offset, 5)

        let inserted = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "12,345",
            range: NSRange(location: 2, length: 0),
            replacement: "9",
            currentSelection: NSRange(location: 2, length: 0),
            mode: .whole,
            locale: unitedStates
        ))
        XCTAssertEqual(inserted.editingCanonicalValue, "129345")
        XCTAssertEqual(inserted.displayedValue, "129,345")
        XCTAssertEqual(inserted.caretUTF16Offset, 3)
    }

    func testLiveAmountEditingDoesNotGetStuckOnGroupingComma() throws {
        let backward = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "1,234",
            range: NSRange(location: 1, length: 1),
            replacement: "",
            currentSelection: NSRange(location: 2, length: 0),
            mode: .whole,
            locale: unitedStates
        ))
        XCTAssertEqual(backward.committedCanonicalValue, "234")
        XCTAssertEqual(backward.displayedValue, "234")
        XCTAssertEqual(backward.caretUTF16Offset, 0)

        let forward = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "1,234",
            range: NSRange(location: 1, length: 1),
            replacement: "",
            currentSelection: NSRange(location: 1, length: 0),
            mode: .whole,
            locale: unitedStates
        ))
        XCTAssertEqual(forward.committedCanonicalValue, "134")
        XCTAssertEqual(forward.displayedValue, "134")
        XCTAssertEqual(forward.caretUTF16Offset, 1)
    }

    func testLiveDecimalEditingPreservesTransientZeroButCommitsTrimmedValue() throws {
        let separator = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "1",
            range: NSRange(location: 1, length: 0),
            replacement: ",",
            currentSelection: NSRange(location: 1, length: 0),
            mode: .decimal(maximumFractionDigits: 2),
            locale: germany
        ))
        XCTAssertEqual(separator.editingCanonicalValue, "1.")
        XCTAssertEqual(separator.committedCanonicalValue, "1")
        XCTAssertEqual(separator.displayedValue, "1.")

        let transientZero = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: separator.displayedValue,
            range: NSRange(location: 2, length: 0),
            replacement: "0",
            currentSelection: NSRange(location: 2, length: 0),
            mode: .decimal(maximumFractionDigits: 2),
            locale: germany
        ))
        XCTAssertEqual(transientZero.editingCanonicalValue, "1.0")
        XCTAssertEqual(transientZero.committedCanonicalValue, "1")
        XCTAssertEqual(transientZero.displayedValue, "1.0")

        let completed = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: transientZero.displayedValue,
            range: NSRange(location: 3, length: 0),
            replacement: "5",
            currentSelection: NSRange(location: 3, length: 0),
            mode: .decimal(maximumFractionDigits: 2),
            locale: germany
        ))
        XCTAssertEqual(completed.editingCanonicalValue, "1.05")
        XCTAssertEqual(completed.committedCanonicalValue, "1.05")
        XCTAssertEqual(completed.displayedValue, "1.05")
    }

    func testAmountPasteCanonicalizesSeparatorsAndPreservesSelection() throws {
        let pasted = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "12,345.67",
            range: NSRange(location: 0, length: 9),
            replacement: "EUR 1.856,80",
            currentSelection: NSRange(location: 0, length: 9),
            mode: .decimal(maximumFractionDigits: 2),
            locale: germany
        ))
        XCTAssertEqual(pasted.editingCanonicalValue, "1856.8")
        XCTAssertEqual(pasted.committedCanonicalValue, "1856.8")
        XCTAssertEqual(pasted.displayedValue, "1,856.8")
        XCTAssertEqual(pasted.caretUTF16Offset, 7)

        let pastedWhole = try XCTUnwrap(PaymentInputFormatting.applyingEdit(
            to: "",
            range: NSRange(location: 0, length: 0),
            replacement: "1000.00",
            currentSelection: NSRange(location: 0, length: 0),
            mode: .decimal(maximumFractionDigits: 2),
            locale: unitedStates
        ))
        XCTAssertEqual(pastedWhole.editingCanonicalValue, "1000")
        XCTAssertEqual(pastedWhole.committedCanonicalValue, "1000")
        XCTAssertEqual(pastedWhole.displayedValue, "1,000")
        XCTAssertEqual(pastedWhole.caretUTF16Offset, 5)

        XCTAssertNil(PaymentInputFormatting.applyingEdit(
            to: "1,000",
            range: NSRange(location: 5, length: 0),
            replacement: ".5",
            currentSelection: NSRange(location: 5, length: 0),
            mode: .whole,
            locale: unitedStates
        ))
    }

    /// `decimalPad` draws the locale's separator, so this is exactly what the customer typed.
    /// Reading it as `150` submitted a hundred times the intended amount.
    func testCommaDecimalSeparatorIsNotReadAsAWholeNumber() {
        XCTAssertEqual(
            PaymentInputFormatting.normalizedDecimalInput(
                "1,50",
                maximumFractionDigits: 2,
                locale: germany
            ),
            "1.50"
        )
        XCTAssertEqual(
            PaymentInputFormatting.normalizedDecimalInput(
                "1,50",
                maximumFractionDigits: 2,
                locale: france
            ),
            "1.50"
        )
    }

    func testGroupingSeparatorIsStrippedRatherThanTreatedAsADecimalPoint() {
        XCTAssertEqual(
            PaymentInputFormatting.normalizedDecimalInput(
                "1.234,50",
                maximumFractionDigits: 2,
                locale: germany
            ),
            "1234.50"
        )
        XCTAssertEqual(
            PaymentInputFormatting.normalizedDecimalInput(
                "1,234.50",
                maximumFractionDigits: 2,
                locale: unitedStates
            ),
            "1234.50"
        )
    }

    /// What the field shows has to parse back to what it was rendered from, or every edit of an
    /// existing amount corrupts it.
    func testDisplayedAmountRoundTripsBackToTheCanonicalValue() {
        for locale in [unitedStates, germany, france] {
            let displayed = PaymentInputFormatting.groupedDecimalInput(
                "1234.50",
                maximumFractionDigits: 2,
                locale: locale
            )
            XCTAssertEqual(
                PaymentInputFormatting.normalizedDecimalInput(
                    displayed,
                    maximumFractionDigits: 2,
                    locale: locale
                ),
                "1234.50",
                "round trip failed for \(locale.identifier) via \(displayed)"
            )
        }
    }

    /// The canonical value the app stores, and the amounts the backend sends, always use `.`
    /// whatever the customer's region is.
    func testCanonicalAmountsAreRenderedInLocalSeparatorsWithoutBeingMisread() {
        XCTAssertEqual(
            PaymentInputFormatting.groupedDecimalInput(
                "1234.50",
                maximumFractionDigits: 2,
                locale: germany
            ),
            "1.234,50"
        )
    }

    func testTrailingFractionZeroTrimmingFollowsTheLocaleSeparator() {
        XCTAssertEqual(
            PaymentInputFormatting.trimmingZeroFraction(
                "1,234.00",
                maximumFractionDigits: 2,
                locale: unitedStates
            ),
            "1,234"
        )
        XCTAssertEqual(
            PaymentInputFormatting.trimmingZeroFraction(
                "1.234,00",
                maximumFractionDigits: 2,
                locale: germany
            ),
            "1.234"
        )
        XCTAssertEqual(
            PaymentInputFormatting.trimmingZeroFraction(
                "1,234.50",
                maximumFractionDigits: 2,
                locale: unitedStates
            ),
            "1,234.5"
        )
    }

    func testMobileMoneyVerificationBodySendsExactCanonicalPhone() throws {
        let phone = try XCTUnwrap(UgandaMobileMoneyPhone.apiValue(from: "0750 000 002"))
        let request = CreateMobileMoneyVerificationRequest(network: "MTN", phoneNumber: phone)

        let object = try jsonObject(request)

        XCTAssertEqual(object["network"] as? String, "MTN")
        XCTAssertEqual(object["phone_number"] as? String, "256750000002")
        XCTAssertEqual(Set(object.keys), ["network", "phone_number"])
    }

    func testLegacyCollectionStepUpAndRequestUseTheSameExactAmount() throws {
        let amount = try XCTUnwrap(MobileMoneyAmount.wholeUnitAPIAmount("400", scale: 2))
        let request = CreateLegacyMobileMoneyCollectionRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: amount
        )
        let object = try jsonObject(request)
        XCTAssertEqual(object["wallet_id"] as? String, "wallet-id")
        XCTAssertEqual(object["account_id"] as? String, "account-id")
        XCTAssertEqual(object["amount"] as? String, "400.00")

        let intent: [String: String?] = [
            "action": "collection",
            "wallet_id": "wallet-id",
            "mobile_money_account_id": "account-id",
            "network": "MTN",
            "amount": amount,
            "currency": "UGX",
        ]
        XCTAssertEqual(intent["amount"]!, "400.00")
    }

    func testCollectionQuoteRequestIsAdditiveAndUsesExplicitFeeMode() throws {
        let request = CreateMobileMoneyCollectionQuoteRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: "500.00",
            feeMode: .grossUp
        )

        let object = try jsonObject(request)

        XCTAssertEqual(object["wallet_id"] as? String, "wallet-id")
        XCTAssertEqual(object["account_id"] as? String, "account-id")
        XCTAssertEqual(object["amount"] as? String, "500.00")
        XCTAssertEqual(object["fee_mode"] as? String, "gross_up")
        XCTAssertEqual(Set(object.keys), ["wallet_id", "account_id", "amount", "fee_mode"])
    }

    func testCollectionQuoteBindsExactDisclosureToStepUp() throws {
        let quote: MobileMoneyCollectionQuoteDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"collection",
              "fee_mode":"gross_up",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"MTN",
              "requested_amount":"500.00",
              "provider_amount":"517.00",
              "provider_fee":"12.93",
              "platform_fee":"3.62",
              "rounding_adjustment":"0.45",
              "total_fees":"17.00",
              "wallet_credit":"500.00",
              "currency":{"code":"UGX","scale":"2"},
              "provider_fee_estimated":true,
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{
                "purpose":"mobile_money_collection",
                "intent":{
                  "action":"collection",
                  "quote_id":"11111111-1111-1111-1111-111111111111",
                  "wallet_id":"22222222-2222-2222-2222-222222222222",
                  "mobile_money_account_id":"33333333-3333-3333-3333-333333333333",
                  "network":"MTN",
                  "fee_mode":"gross_up",
                  "requested_amount":"500.00",
                  "provider_amount":"517.00",
                  "provider_fee":"12.93",
                  "platform_fee":"3.62",
                  "rounding_adjustment":"0.45",
                  "total_fees":"17.00",
                  "wallet_credit":"500.00",
                  "currency":"UGX"
                }
              }
            }
            """
        )

        XCTAssertEqual(quote.feeMode, .grossUp)
        XCTAssertEqual(quote.providerAmount, "517.00")
        XCTAssertEqual(quote.totalFees, "17.00")
        XCTAssertEqual(quote.walletCredit, "500.00")
        XCTAssertFalse(quote.isExpired)
        XCTAssertEqual(quote.stepUp.purpose, "mobile_money_collection")
        XCTAssertEqual(quote.stepUp.intent["quote_id"], quote.id)
        XCTAssertTrue(quote.hasValidStepUpBinding)
        let customerFields = Set(Mirror(reflecting: quote).children.compactMap(\.label))
        XCTAssertTrue(customerFields.isDisjoint(with: [
            "providerFee", "platformFee", "roundingAdjustment", "providerFeeEstimated",
        ]))

        let operation = try jsonObject(CreateQuotedMobileMoneyCollectionRequest(quoteId: quote.id))
        XCTAssertEqual(operation["quote_id"] as? String, quote.id)
        XCTAssertEqual(Set(operation.keys), ["quote_id"])
    }

    func testAggregateOnlyCollectionQuoteRejectsUnknownScopeAndStepUpExtras() throws {
        let json =
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"collection",
              "fee_mode":"gross_up",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"MTN",
              "requested_amount":"500.00",
              "provider_amount":"517.00",
              "total_fees":"17.00",
              "wallet_credit":"500.00",
              "pricing_scope":"customer_totals",
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{
                "purpose":"mobile_money_collection",
                "intent":{
                  "action":"collection",
                  "quote_id":"11111111-1111-1111-1111-111111111111",
                  "wallet_id":"22222222-2222-2222-2222-222222222222",
                  "mobile_money_account_id":"33333333-3333-3333-3333-333333333333",
                  "network":"MTN",
                  "fee_mode":"gross_up",
                  "requested_amount":"500.00",
                  "provider_amount":"517.00",
                  "total_fees":"17.00",
                  "wallet_credit":"500.00",
                  "currency":"UGX"
                }
              }
            }
            """
        let quote: MobileMoneyCollectionQuoteDTO = try decode(json)

        XCTAssertEqual(quote.pricingScope, CustomerPricingContract.scope)
        XCTAssertTrue(quote.hasConsistentCustomerAmounts)
        XCTAssertTrue(quote.hasValidStepUpBinding)

        let unknownScope: MobileMoneyCollectionQuoteDTO = try decode(
            json.replacingOccurrences(of: "customer_totals", with: "institutional_split")
        )
        XCTAssertFalse(unknownScope.hasConsistentCustomerAmounts)

        let wrongFeeTreatment: MobileMoneyCollectionQuoteDTO = try decode(
            json.replacingOccurrences(of: "gross_up", with: "inclusive")
        )
        XCTAssertFalse(wrongFeeTreatment.hasConsistentCustomerAmounts)

        let inclusive: MobileMoneyCollectionQuoteDTO = try decode(
            json
                .replacingOccurrences(of: "gross_up", with: "inclusive")
                .replacingOccurrences(
                    of: "\"provider_amount\":\"517.00\"",
                    with: "\"provider_amount\":\"500.00\""
                )
                .replacingOccurrences(
                    of: "\"wallet_credit\":\"500.00\"",
                    with: "\"wallet_credit\":\"483.00\""
                )
        )
        XCTAssertTrue(inclusive.hasConsistentCustomerAmounts)
        XCTAssertTrue(inclusive.hasValidStepUpBinding)

        let unknownIntentKey: MobileMoneyCollectionQuoteDTO = try decode(
            json.replacingOccurrences(of: "\"intent\":{", with: "\"intent\":{\"private_margin\":\"1.00\",")
        )
        XCTAssertFalse(unknownIntentKey.hasValidStepUpBinding)
    }

    func testPayoutQuoteRequestUsesExplicitFeePayerAndWholeUGXAmount() throws {
        let request = CreateMobileMoneyPayoutQuoteRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: "500.00",
            feeMode: .senderAbsorbs
        )

        let object = try jsonObject(request)

        XCTAssertEqual(object["wallet_id"] as? String, "wallet-id")
        XCTAssertEqual(object["account_id"] as? String, "account-id")
        XCTAssertEqual(object["amount"] as? String, "500.00")
        XCTAssertEqual(object["fee_mode"] as? String, "sender_absorbs")
        XCTAssertEqual(Set(object.keys), ["wallet_id", "account_id", "amount", "fee_mode"])
    }

    func testBeneficiaryCoveredPayoutDeductsFeeBeforeRecipientReceivesFunds() throws {
        let request = CreateMobileMoneyPayoutQuoteRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: "500.00",
            feeMode: .beneficiaryAbsorbs
        )
        let object = try jsonObject(request)
        XCTAssertEqual(object["fee_mode"] as? String, "recipient_absorbs")

        let quote: MobileMoneyPayoutQuoteDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"payout",
              "fee_mode":"recipient_absorbs",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"MTN",
              "recipient_amount":"350.00",
              "processing_fee":"150.00",
              "provider_fee":"100.00",
              "kit_fee":"50.00",
              "provider_fee_cap":"100.00",
              "maximum_provider_total":"450.00",
              "customer_debit":"500.00",
              "kit_debit":"0.00",
              "schedule_version":"kit-mobile-v1-20260819",
              "schedule_verified":true,
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{"purpose":"mobile_money_payout","intent":{}}
            }
            """
        )

        XCTAssertEqual(quote.feeMode, .beneficiaryAbsorbs)
        XCTAssertEqual(quote.enteredAmount, "500.00")
        XCTAssertEqual(quote.recipientAmount, "350.00")
        XCTAssertEqual(quote.customerDebit, "500.00")
        XCTAssertTrue(quote.hasConsistentAmounts)

        let pricing = MobileMoneyOutboundPricingDTO(
            feeMode: quote.feeMode,
            recipientAmount: quote.recipientAmount,
            processingFee: quote.processingFee,
            customerDebit: quote.customerDebit
        )
        XCTAssertTrue(pricing.hasConsistentAmounts)
        XCTAssertTrue(pricing.matches(quote))

        let aggregatePricing = MobileMoneyOutboundPricingDTO(
            feeMode: quote.feeMode,
            recipientAmount: quote.recipientAmount,
            processingFee: quote.processingFee,
            totalFees: quote.processingFee,
            pricingScope: CustomerPricingContract.scope,
            customerDebit: quote.customerDebit
        )
        XCTAssertTrue(aggregatePricing.hasConsistentAmounts)
        XCTAssertTrue(aggregatePricing.matches(quote))
    }

    func testPayoutQuoteBindsRecipientFeeAndExactDebitToStepUp() throws {
        let quote: MobileMoneyPayoutQuoteDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"payout",
              "fee_mode":"sender_absorbs",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"MTN",
              "recipient_amount":"500.00",
              "processing_fee":"1500.00",
              "provider_fee":"1500.00",
              "kit_fee":"0.00",
              "provider_fee_cap":"1500.00",
              "maximum_provider_total":"2000.00",
              "customer_debit":"2000.00",
              "kit_debit":"0.00",
              "schedule_version":"rukapay-v8-20260818",
              "schedule_verified":true,
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{
                "purpose":"mobile_money_payout",
                "intent":{
                  "action":"payout",
                  "quote_id":"11111111-1111-1111-1111-111111111111",
                  "wallet_id":"22222222-2222-2222-2222-222222222222",
                  "mobile_money_account_id":"33333333-3333-3333-3333-333333333333",
                  "network":"MTN",
                  "fee_mode":"sender_absorbs",
                  "recipient_amount":"500.00",
                  "processing_fee":"1500.00",
                  "provider_fee":"1500.00",
                  "kit_fee":"0.00",
                  "provider_fee_cap":"1500.00",
                  "maximum_provider_total":"2000.00",
                  "customer_debit":"2000.00",
                  "kit_debit":"0.00",
                  "schedule_version":"rukapay-v8-20260818",
                  "currency":"UGX"
                }
              }
            }
            """
        )

        XCTAssertEqual(quote.feeMode, .senderAbsorbs)
        XCTAssertEqual(quote.recipientAmount, "500.00")
        XCTAssertEqual(quote.processingFee, "1500.00")
        XCTAssertEqual(quote.customerDebit, "2000.00")
        XCTAssertTrue(quote.scheduleVerified)
        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertFalse(quote.isExpired)
        XCTAssertEqual(quote.stepUp.purpose, "mobile_money_payout")
        XCTAssertEqual(quote.stepUp.intent["quote_id"], quote.id)
        XCTAssertEqual(quote.stepUp.intent["customer_debit"], quote.customerDebit)
        XCTAssertTrue(quote.hasValidStepUpBinding)
        let customerFields = Set(Mirror(reflecting: quote).children.compactMap(\.label))
        XCTAssertTrue(customerFields.isDisjoint(with: [
            "providerFee", "kitFee", "providerFeeCap", "maximumProviderTotal", "kitDebit",
            "scheduleVersion",
        ]))

        let operation = try jsonObject(CreateQuotedMobileMoneyPayoutRequest(quoteId: quote.id))
        XCTAssertEqual(operation["quote_id"] as? String, quote.id)
        XCTAssertEqual(Set(operation.keys), ["quote_id"])
    }

    func testAggregateOnlyPayoutQuoteRejectsConflictingTotalsScopeAndStepUpExtras() throws {
        let json =
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"payout",
              "fee_mode":"sender_absorbs",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"MTN",
              "recipient_amount":"500.00",
              "processing_fee":"1500.00",
              "total_fees":"1500.00",
              "customer_debit":"2000.00",
              "pricing_scope":"customer_totals",
              "schedule_verified":true,
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{
                "purpose":"mobile_money_payout",
                "intent":{
                  "action":"payout",
                  "quote_id":"11111111-1111-1111-1111-111111111111",
                  "wallet_id":"22222222-2222-2222-2222-222222222222",
                  "mobile_money_account_id":"33333333-3333-3333-3333-333333333333",
                  "network":"MTN",
                  "fee_mode":"sender_absorbs",
                  "recipient_amount":"500.00",
                  "processing_fee":"1500.00",
                  "customer_debit":"2000.00",
                  "currency":"UGX"
                }
              }
            }
            """
        let quote: MobileMoneyPayoutQuoteDTO = try decode(json)

        XCTAssertEqual(quote.totalFees, "1500.00")
        XCTAssertEqual(quote.pricingScope, CustomerPricingContract.scope)
        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertTrue(quote.hasValidStepUpBinding)

        let mismatchedTotal: MobileMoneyPayoutQuoteDTO = try decode(
            json.replacingOccurrences(of: "\"total_fees\":\"1500.00\"", with: "\"total_fees\":\"1499.00\"")
        )
        XCTAssertFalse(mismatchedTotal.hasConsistentAmounts)

        let unknownScope: MobileMoneyPayoutQuoteDTO = try decode(
            json.replacingOccurrences(of: "customer_totals", with: "institutional_split")
        )
        XCTAssertFalse(unknownScope.hasConsistentAmounts)

        let unknownIntentKey: MobileMoneyPayoutQuoteDTO = try decode(
            json.replacingOccurrences(of: "\"intent\":{", with: "\"intent\":{\"private_margin\":\"1.00\",")
        )
        XCTAssertFalse(unknownIntentKey.hasValidStepUpBinding)
    }

    func testKitCoveredPayoutStillPreservesFullRecipientAmount() throws {
        let quote: MobileMoneyPayoutQuoteDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "action":"payout",
              "fee_mode":"kit_covers",
              "wallet_id":"22222222-2222-2222-2222-222222222222",
              "account_id":"33333333-3333-3333-3333-333333333333",
              "network":"AIRTEL",
              "recipient_amount":"500.00",
              "processing_fee":"1500.00",
              "provider_fee":"1500.00",
              "kit_fee":"0.00",
              "provider_fee_cap":"1500.00",
              "maximum_provider_total":"2000.00",
              "customer_debit":"500.00",
              "kit_debit":"1500.00",
              "schedule_version":"rukapay-v8-20260818",
              "schedule_verified":true,
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T12:05:00Z",
              "step_up":{"purpose":"mobile_money_payout","intent":{}}
            }
            """
        )

        XCTAssertEqual(quote.feeMode, .kitCovers)
        XCTAssertEqual(quote.recipientAmount, quote.customerDebit)
        XCTAssertTrue(quote.hasConsistentAmounts)
    }

    func testLegacyAndroidCollectionBodyRemainsExactlyUnchanged() throws {
        let request = CreateLegacyMobileMoneyCollectionRequest(
            walletId: "wallet-id",
            accountId: "account-id",
            amount: "500.00"
        )
        let object = try jsonObject(request)

        XCTAssertEqual(Set(object.keys), ["wallet_id", "account_id", "amount"])
        XCTAssertNil(object["fee_mode"])
        XCTAssertNil(object["quote_id"])
    }

    func testMobileMoneyOperationDecodesNullableProviderFields() throws {
        let json =
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "reference":"MM-1",
              "type":"deposit",
              "direction":"inbound",
              "status":"pending",
              "submission_stage":null,
              "bank_id":"22222222-2222-2222-2222-222222222222",
              "beneficiary_id":null,
              "wallet_id":"33333333-3333-3333-3333-333333333333",
              "amount":"517.00",
              "currency":{"code":"UGX","scale":"2"},
              "provider_reference":null,
              "wallet_transaction_id":null,
              "failure":null,
              "created_at":"2026-08-18T12:00:00Z",
              "completed_at":null,
              "mobile_money_type":"collection",
              "fee_quote_id":"44444444-4444-4444-4444-444444444444",
              "fee_mode":"gross_up",
              "requested_amount":"500.00",
              "provider_fee":"17.00",
              "platform_fee":"0.00",
              "rounding_adjustment":"0.00",
              "total_fees":"17.00",
              "net_amount":"500.00",
              "pricing_scope":"customer_totals",
              "network":{
                "id":"22222222-2222-2222-2222-222222222222",
                "code":"MTN",
                "name":"MTN Mobile Money",
                "currency":{"code":"UGX","scale":"2"},
                "capabilities":{"collections":true,"payouts":true,"account_verification":true}
              }
            }
            """
        let operation: MobileMoneyOperationDTO = try decode(json)
        XCTAssertEqual(operation.mobileMoneyType, "collection")
        XCTAssertEqual(operation.amount, "517.00")
        XCTAssertFalse(operation.isTerminal)
        XCTAssertNil(operation.providerReference)
        XCTAssertEqual(operation.feeMode, .grossUp)
        XCTAssertEqual(operation.netAmount, "500.00")
        XCTAssertEqual(operation.totalFees, "17.00")
        XCTAssertEqual(operation.pricingScope, CustomerPricingContract.scope)
        XCTAssertEqual(operation.customerTransactionFee, "17.00")
        XCTAssertEqual(operation.customerImpactLabel, "Money Added")
        XCTAssertEqual(operation.customerImpactAmount, "500.00")
        XCTAssertNil(operation.outboundPricing)

        let untrusted: MobileMoneyOperationDTO = try decode(
            json.replacingOccurrences(of: "customer_totals", with: "institutional_split")
        )
        XCTAssertNil(untrusted.customerTransactionFee)
        XCTAssertNil(untrusted.customerImpactAmount)

        let inconsistent: MobileMoneyOperationDTO = try decode(
            json.replacingOccurrences(
                of: "\"net_amount\":\"500.00\"",
                with: "\"net_amount\":\"499.00\""
            )
        )
        XCTAssertNil(inconsistent.customerTransactionFee)
        XCTAssertNil(inconsistent.customerImpactAmount)
    }

    func testMobileMoneyOperationDecodesLegacyResponseWithoutFeeFields() throws {
        let operation: MobileMoneyOperationDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "reference":"MM-LEGACY",
              "type":"deposit",
              "direction":"credit",
              "status":"pending",
              "submission_stage":"queued",
              "bank_id":"22222222-2222-2222-2222-222222222222",
              "beneficiary_id":"33333333-3333-3333-3333-333333333333",
              "wallet_id":"44444444-4444-4444-4444-444444444444",
              "amount":"500.00",
              "currency":{"code":"UGX","scale":"2"},
              "provider_reference":null,
              "wallet_transaction_id":null,
              "failure":null,
              "created_at":null,
              "completed_at":null,
              "mobile_money_type":"collection",
              "network":{
                "id":"22222222-2222-2222-2222-222222222222",
                "code":"MTN",
                "name":"MTN Mobile Money",
                "currency":{"code":"UGX","scale":"2"},
                "capabilities":{"collections":true,"payouts":true,"account_verification":true}
              }
            }
            """
        )

        XCTAssertEqual(operation.amount, "500.00")
        XCTAssertNil(operation.feeQuoteId)
        XCTAssertNil(operation.feeMode)
        XCTAssertNil(operation.totalFees)
        XCTAssertNil(operation.netAmount)
        XCTAssertNil(operation.outboundQuoteId)
        XCTAssertNil(operation.outboundPricing)
        XCTAssertNil(operation.customerImpactLabel)
        XCTAssertNil(operation.customerImpactAmount)
        XCTAssertFalse(MobileMoneyOperationPresentationPolicy.isCustomerVisible(operation))
    }

    func testMobileMoneyOperationRefreshPolicyPollsPendingRowsWithBoundedBackoff() {
        let pending = mobileMoneyOperation(
            status: "pending",
            type: "collection",
            failureCode: ""
        )
        let succeeded = mobileMoneyOperation(
            status: "succeeded",
            type: "collection",
            failureCode: ""
        )

        XCTAssertTrue(MobileMoneyOperationRefreshPolicy.shouldPoll(
            pending,
            isActive: true,
            isOnline: true
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.shouldPoll(
            pending,
            isActive: false,
            isOnline: true
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.shouldPoll(
            pending,
            isActive: true,
            isOnline: false
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.shouldPoll(
            succeeded,
            isActive: true,
            isOnline: true
        ))

        XCTAssertEqual(MobileMoneyOperationRefreshPolicy.interval(attempt: -1), 1.5)
        var previous = MobileMoneyOperationRefreshPolicy.interval(attempt: 0)
        for attempt in 1...30 {
            let interval = MobileMoneyOperationRefreshPolicy.interval(attempt: attempt)
            XCTAssertGreaterThanOrEqual(interval, previous)
            XCTAssertLessThanOrEqual(
                interval,
                MobileMoneyOperationRefreshPolicy.maximumInterval
            )
            previous = interval
        }
        XCTAssertEqual(
            MobileMoneyOperationRefreshPolicy.interval(attempt: 30),
            MobileMoneyOperationRefreshPolicy.maximumInterval
        )
        XCTAssertEqual(
            MobileMoneyOperationRefreshPolicy.nextAttempt(after: Int.max),
            MobileMoneyOperationRefreshPolicy.maximumBackoffAttempt
        )
    }

    func testMobileMoneyOperationRefreshAcceptsOnlyTheSameImmutablePayment() {
        let pending = mobileMoneyOperation(
            status: "pending",
            type: "payout",
            failureCode: ""
        )
        let settled = mobileMoneyOperation(
            status: "succeeded",
            type: "payout",
            failureCode: ""
        )
        let differentOperation = mobileMoneyOperation(
            id: "99999999-9999-4999-8999-999999999999",
            status: "succeeded",
            type: "payout",
            failureCode: ""
        )
        let differentWallet = mobileMoneyOperation(
            walletId: "88888888-8888-4888-8888-888888888888",
            status: "succeeded",
            type: "payout",
            failureCode: ""
        )
        let differentBeneficiary = mobileMoneyOperation(
            status: "succeeded",
            type: "payout",
            failureCode: "",
            beneficiaryId: "77777777-7777-4777-8777-777777777777"
        )

        XCTAssertTrue(MobileMoneyOperationRefreshPolicy.hasSameImmutableIdentity(
            settled,
            as: pending
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.hasSameImmutableIdentity(
            differentOperation,
            as: pending
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.hasSameImmutableIdentity(
            differentWallet,
            as: pending
        ))
        XCTAssertFalse(MobileMoneyOperationRefreshPolicy.hasSameImmutableIdentity(
            differentBeneficiary,
            as: pending
        ))
    }

    func testMobileMoneyCustomerStatusCopyDistinguishesPaidPayouts() {
        func status(_ state: String, type: String) -> String {
            MobileMoneyOperationStatusPresentation.customerText(for: mobileMoneyOperation(
                status: state,
                type: type,
                failureCode: ""
            ))
        }

        XCTAssertEqual(status("succeeded", type: "payout"), "Paid")
        XCTAssertEqual(status("completed", type: "collection"), "Completed")
        XCTAssertEqual(status("failed", type: "payout"), "Failed")
        XCTAssertEqual(status("reversed", type: "collection"), "Reversed")
        XCTAssertEqual(status("canceled", type: "payout"), "Cancelled")
        XCTAssertEqual(status("processing", type: "payout"), "Processing")
    }

    func testMobileMoneyRemoteWakeRefreshesOnlyForTypedTerminalEvents() {
        let terminalTypes = [
            "mobile_money.collection.succeeded",
            "mobile_money.collection.failed",
            "mobile_money.collection.reversed",
            "mobile_money.payout.succeeded",
            "mobile_money.payout.failed",
            "mobile_money.payout.reversed",
        ]
        for eventType in terminalTypes {
            XCTAssertTrue(MobileMoneyRemoteWakePolicy.shouldRefreshOperations(
                for: ["type": eventType]
            ), eventType)
        }

        let unrelatedObjects: [Any?] = [
            ["type": "mobile_money.collection.processing"],
            ["type": "message.created"],
            ["type": "mobile_money.collection.succeeded "],
            ["type": "MOBILE_MONEY.PAYOUT.SUCCEEDED"],
            ["event_type": "mobile_money.payout.succeeded"],
            ["type": 1],
            "mobile_money.payout.succeeded",
            nil,
        ]
        for object in unrelatedObjects {
            XCTAssertFalse(MobileMoneyRemoteWakePolicy.shouldRefreshOperations(for: object))
        }
    }

    func testConfirmedCollectionFailureCopyRequiresAFailedCollection() {
        let expected = CustomerFacingPaymentCopy.confirmedMobileMoneyCollectionFailure
        let failedCollection = mobileMoneyOperation(
            status: "failed",
            type: "collection",
            failureCode: "BANK_PROVIDER_FAILED"
        )
        let pendingCollection = mobileMoneyOperation(
            status: "pending",
            type: "collection",
            failureCode: "BANK_PROVIDER_FAILED"
        )
        let failedPayout = mobileMoneyOperation(
            status: "failed",
            type: "payout",
            failureCode: "BANK_PROVIDER_FAILED"
        )
        let unknownCollection = mobileMoneyOperation(
            status: "failed",
            type: "collection",
            failureCode: "BANK_PROVIDER_OUTCOME_UNKNOWN"
        )

        XCTAssertEqual(failedCollection.confirmedCollectionFailureMessage, expected)
        XCTAssertNil(pendingCollection.confirmedCollectionFailureMessage)
        XCTAssertNil(failedPayout.confirmedCollectionFailureMessage)
        XCTAssertNil(unknownCollection.confirmedCollectionFailureMessage)
    }

    func testMobileMoneyPayoutOperationConfirmsItsImmutableQuote() throws {
        let operation: MobileMoneyOperationDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "reference":"MM-PAYOUT-1",
              "type":"withdrawal",
              "direction":"outbound",
              "status":"pending",
              "submission_stage":"queued",
              "bank_id":"22222222-2222-2222-2222-222222222222",
              "beneficiary_id":"33333333-3333-3333-3333-333333333333",
              "wallet_id":"44444444-4444-4444-4444-444444444444",
              "amount":"500.00",
              "currency":{"code":"UGX","scale":"2"},
              "provider_reference":null,
              "wallet_transaction_id":null,
              "failure":null,
              "created_at":"2026-08-18T12:00:00Z",
              "completed_at":null,
              "mobile_money_type":"payout",
              "outbound_quote_id":"55555555-5555-5555-5555-555555555555",
              "outbound_pricing":{
                "fee_mode":"sender_absorbs",
                "recipient_amount":"500.00",
                "processing_fee":"10.00",
                "total_fees":"10.00",
                "pricing_scope":"customer_totals",
                "provider_fee":"10.00",
                "kit_fee":"0.00",
                "provider_fee_cap":"10.00",
                "maximum_provider_total":"510.00",
                "customer_debit":"510.00",
                "kit_debit":"0.00",
                "schedule_version":"rukapay-v8-20260818",
                "actual_provider_fee":null,
                "actual_provider_total":null
              },
              "network":{
                "id":"22222222-2222-2222-2222-222222222222",
                "code":"MTN",
                "name":"MTN Mobile Money",
                "currency":{"code":"UGX","scale":"2"},
                "capabilities":{"collections":true,"payouts":true,"account_verification":true}
              }
            }
            """
        )

        XCTAssertEqual(operation.mobileMoneyType, "payout")
        XCTAssertEqual(operation.outboundQuoteId, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(operation.amount, "500.00")
        XCTAssertEqual(operation.outboundPricing?.feeMode, .senderAbsorbs)
        XCTAssertEqual(operation.outboundPricing?.recipientAmount, "500.00")
        XCTAssertEqual(operation.outboundPricing?.processingFee, "10.00")
        XCTAssertEqual(operation.outboundPricing?.totalFees, "10.00")
        XCTAssertEqual(operation.outboundPricing?.pricingScope, CustomerPricingContract.scope)
        XCTAssertEqual(operation.customerTransactionFee, "10.00")
        XCTAssertEqual(operation.outboundPricing?.customerDebit, "510.00")
        XCTAssertEqual(operation.customerImpactLabel, "Money Deducted")
        XCTAssertEqual(operation.customerImpactAmount, "510.00")
        let customerFields = Set(
            Mirror(reflecting: try XCTUnwrap(operation.outboundPricing)).children.compactMap(\.label)
        )
        XCTAssertTrue(customerFields.isDisjoint(with: [
            "providerFee", "kitFee", "providerFeeCap", "maximumProviderTotal", "kitDebit",
            "actualProviderFee", "actualProviderTotal", "scheduleVersion",
        ]))

        let untrustedPricing = MobileMoneyOutboundPricingDTO(
            feeMode: .senderAbsorbs,
            recipientAmount: "500.00",
            processingFee: "10.00",
            totalFees: "10.00",
            pricingScope: "institutional_split",
            customerDebit: "510.00"
        )
        let untrusted = mobileMoneyOperation(
            status: "pending",
            type: MobileMoneyAction.payout.rawValue,
            failureCode: "",
            outboundPricing: untrustedPricing
        )
        XCTAssertNil(untrusted.customerTransactionFee)
        XCTAssertNil(untrusted.customerImpactAmount)
    }

    func testMerchantQRResolutionAndPaymentModelsDecode() throws {
        let code: MerchantQRCodeDTO = try decode(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "type":"merchant_qr",
              "kind":"dynamic",
              "status":"active",
              "merchant":{
                "id":"22222222-2222-2222-2222-222222222222",
                "public_id":"33333333-3333-3333-3333-333333333333",
                "display_name":"QR Shop"
              },
              "merchant_payment_intent_id":"44444444-4444-4444-4444-444444444444",
              "amount":"12.50",
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2026-08-19T12:00:00Z",
              "created_at":"2026-08-18T12:00:00Z"
            }
            """
        )
        XCTAssertTrue(code.isDynamic)
        XCTAssertTrue(code.isPayable)
        XCTAssertEqual(code.merchant.displayName, "QR Shop")
        XCTAssertEqual(code.amount, "12.50")
    }

    func testMerchantQRPayloadHashMatchesBackendSHA256Contract() {
        let payload = "kitpay://merchant?id=example&amount=1250"
        let digest = SHA256.hash(data: Data(payload.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
    }

    func testPaymentRailCapabilitiesRequireEveryServerGate() throws {
        let enabled: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"2"},"features":{
              "wallets":true,"mobile_money":true,"merchant_payments":true,"qr_payments":true
            }}
            """
        )
        XCTAssertTrue(enabled.enablesMobileMoney)
        XCTAssertTrue(enabled.enablesMerchantQRPayments)

        let disabled: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"2"},"features":{
              "wallets":true,"mobile_money":false,"merchant_payments":true,"qr_payments":null
            }}
            """
        )
        XCTAssertFalse(disabled.enablesMobileMoney)
        XCTAssertFalse(disabled.enablesMerchantQRPayments)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func mobileMoneyOperation(
        id: String = "11111111-1111-1111-1111-111111111111",
        walletId: String = "33333333-3333-3333-3333-333333333333",
        status: String,
        type: String,
        failureCode: String,
        operationType: String? = nil,
        direction: String? = nil,
        beneficiaryId: String? = nil,
        walletTransactionId: String? = nil,
        outboundPricing: MobileMoneyOutboundPricingDTO? = nil,
        amount: String = "500.00",
        totalFees: String? = nil,
        netAmount: String? = nil,
        pricingScope: String? = nil
    ) -> MobileMoneyOperationDTO {
        MobileMoneyOperationDTO(
            id: id,
            reference: "MM-FAILURE",
            type: operationType
                ?? (type == MobileMoneyAction.collection.rawValue ? "deposit" : "withdrawal"),
            direction: direction
                ?? (type == MobileMoneyAction.collection.rawValue ? "inbound" : "outbound"),
            status: status,
            submissionStage: status == "failed" ? "terminal" : "awaiting_provider",
            bankId: "22222222-2222-2222-2222-222222222222",
            beneficiaryId: beneficiaryId,
            walletId: walletId,
            amount: amount,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            providerReference: nil,
            walletTransactionId: walletTransactionId,
            failure: MobileMoneyFailureDTO(
                code: failureCode,
                message: "The provider confirmed that the operation failed."
            ),
            createdAt: "2026-08-19T12:00:00Z",
            completedAt: status == "failed" ? "2026-08-19T12:00:10Z" : nil,
            mobileMoneyType: type,
            network: MobileMoneyNetworkDTO(
                id: "22222222-2222-2222-2222-222222222222",
                code: "MTN",
                name: "MTN Mobile Money",
                currency: CurrencyDTO(code: "UGX", scale: "2"),
                capabilities: ["collections": true, "payouts": true]
            ),
            outboundQuoteId: nil,
            outboundPricing: outboundPricing,
            feeQuoteId: nil,
            feeMode: nil,
            requestedAmount: nil,
            totalFees: totalFees,
            netAmount: netAmount,
            pricingScope: pricingScope
        )
    }
}
