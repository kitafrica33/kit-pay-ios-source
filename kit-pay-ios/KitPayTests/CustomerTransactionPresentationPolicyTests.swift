import XCTest
@testable import KitPay

final class CustomerTransactionPresentationPolicyTests: XCTestCase {
    func testHistoryEnvelopeQuarantinesMalformedRowsAndClaimMetadataWithoutLosingSafeActivity()
        async throws {
        let payload = Data(
            """
            {
              "ok": true,
              "data": {
                "items": [
                  {
                    "id": "11111111-1111-4111-8111-111111111111",
                    "wallet_id": "wallet-1",
                    "reference": "KDP-0001",
                    "amount": "500000.00",
                    "totals": {"added": "500000.00", "deducted": "0.00"},
                    "currency": {"code": "UGX", "scale": "2"},
                    "type": "bank_deposit",
                    "direction": "credit",
                    "status": "completed",
                    "counterparty": null,
                    "note": null,
                    "claim": {"id": 7, "can_accept": "yes"},
                    "occurred_at": "2026-09-03T08:30:00Z"
                  },
                  {
                    "id": "22222222-2222-4222-8222-222222222222",
                    "wallet_id": "wallet-1",
                    "reference": "KIT-BAD-CORE",
                    "amount": 150000,
                    "totals": {"added": "0.00", "deducted": "150000.00"},
                    "currency": {"code": "UGX", "scale": "2"},
                    "type": "internal_transfer",
                    "direction": "debit",
                    "status": "completed",
                    "counterparty": null,
                    "note": null,
                    "claim": null,
                    "occurred_at": "2026-09-03T08:29:00Z"
                  },
                  {
                    "id": "33333333-3333-4333-8333-333333333333",
                    "wallet_id": "wallet-1",
                    "reference": "KIT-0003",
                    "amount": "150000.00",
                    "totals": {"added": "0.00", "deducted": "150000.00"},
                    "currency": {"code": "UGX", "scale": "2"},
                    "type": "internal_transfer",
                    "direction": "debit",
                    "status": "completed",
                    "counterparty": {"id": "peer", "name": "Waswa", "phone": null, "account_number": null},
                    "note": "Payment",
                    "claim": null,
                    "occurred_at": "2026-09-03T08:28:00Z"
                  },
                  {
                    "id": "44444444-4444-4444-8444-444444444444",
                    "wallet_id": "wallet-1",
                    "reference": "KIT-INTERNAL",
                    "amount": "250.00",
                    "totals": {"added": "0.00", "deducted": "250.00"},
                    "currency": {"code": "UGX", "scale": "2"},
                    "type": "institutional_commission",
                    "direction": "debit",
                    "status": "completed",
                    "counterparty": null,
                    "note": null,
                    "claim": null,
                    "occurred_at": "2026-09-03T08:27:00Z"
                  }
                ],
                "page": {"next_cursor": null, "has_more": false, "limit": 50}
              },
              "meta": {
                "request_id": "55555555-5555-4555-8555-555555555555",
                "server_time": "2026-09-03T08:31:00Z"
              }
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(APIEnvelope<TransactionPage>.self, from: payload)
        let page = try XCTUnwrap(envelope.data)
        XCTAssertEqual(page.sourceItemCount, 4)
        XCTAssertEqual(page.rejectedItemCount, 1)
        XCTAssertEqual(page.items.map(\.id), [
            "11111111-1111-4111-8111-111111111111",
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
        ])
        XCTAssertNil(page.items[0].claim, "Malformed claim metadata must fail closed by itself")

        let replacement = CustomerTransactionPresentationPolicy.pageReplacement(
            for: page,
            wallet: wallet()
        )
        guard case .replace(let safeRows) = replacement else {
            return XCTFail("Independently valid customer rows must survive one malformed row")
        }
        XCTAssertEqual(safeRows.map(\.id), [
            "11111111-1111-4111-8111-111111111111",
            "33333333-3333-4333-8333-333333333333",
        ])

        // Exercise the same encrypted persistence boundary used by AppModel after a refresh.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitPayWalletHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.secure")
        let key = Data(repeating: 0x58, count: 32)
        let store = SecureLocalStore(stateURL: stateURL, keyData: key)
        var state = PersistedState.empty
        state.wallets = [wallet()]
        state.selectedWalletId = "wallet-1"
        state.transactions = safeRows
        try await store.replace(state)

        let reopened = SecureLocalStore(stateURL: stateURL, keyData: key)
        let restored = await reopened.snapshot()
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                restored.transactions,
                selectedWalletID: restored.selectedWalletId,
                wallets: restored.wallets
            ).map(\.id),
            safeRows.map(\.id)
        )
    }

    func testNonemptyHistoryWhoseEveryCoreRowIsMalformedPreservesLastGoodProjection() throws {
        let payload = Data(
            """
            {
              "items": [
                {
                  "id": "bad-row",
                  "wallet_id": "wallet-1",
                  "reference": "BAD",
                  "amount": 100,
                  "totals": {"added": "100", "deducted": "0"},
                  "currency": {"code": "UGX", "scale": "2"},
                  "type": "bank_deposit",
                  "direction": "credit",
                  "status": "completed",
                  "occurred_at": "2026-09-03T08:30:00Z"
                }
              ],
              "page": {"next_cursor": null, "has_more": false, "limit": 50}
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(TransactionPage.self, from: payload)

        XCTAssertEqual(page.sourceItemCount, 1)
        XCTAssertEqual(page.rejectedItemCount, 1)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(for: page, wallet: wallet()),
            .preserveLastGood
        )
    }

    func testTrulyEmptyHistoryPageStillClearsTheProjection() throws {
        let payload = Data(
            """
            {
              "items": [],
              "page": {"next_cursor": null, "has_more": false, "limit": 50}
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(TransactionPage.self, from: payload)

        XCTAssertEqual(page.sourceItemCount, 0)
        XCTAssertEqual(page.rejectedItemCount, 0)
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(for: page, wallet: wallet()),
            .replace([])
        )
    }

    func testFilteredProductionHistoryDecodesAsDenseArrayAndRemainsVisible() throws {
        // The backend may discard an unprovable accounting row before serializing this page.
        // `items` must still be a dense JSON array (`values()` in Laravel), not an object whose
        // numeric keys retain the gap left by `filter`; an object cannot decode as this contract.
        let payload = Data(
            """
            {
              "items": [
                {
                  "id": "11111111-1111-4111-8111-111111111111",
                  "wallet_id": "wallet-1",
                  "reference": "KDP-0001",
                  "amount": "200000.00",
                  "totals": {"added": "200000.00", "deducted": "0.00"},
                  "currency": {"code": "UGX", "scale": "2"},
                  "type": "bank_deposit",
                  "direction": "credit",
                  "status": "completed",
                  "counterparty": null,
                  "note": null,
                  "claim": null,
                  "occurred_at": "2026-09-01T08:30:00Z"
                },
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "wallet_id": "wallet-1",
                  "reference": "KIT-0002",
                  "amount": "150000.00",
                  "totals": {"added": "0.00", "deducted": "150000.00"},
                  "currency": {"code": "UGX", "scale": "2"},
                  "type": "internal_transfer",
                  "direction": "debit",
                  "status": "completed",
                  "counterparty": null,
                  "note": null,
                  "claim": null,
                  "occurred_at": "2026-09-01T08:25:00Z"
                }
              ],
              "page": {"next_cursor": null, "has_more": false, "limit": 50}
            }
            """.utf8
        )

        let page = try JSONDecoder().decode(TransactionPage.self, from: payload)
        let visible = CustomerTransactionPresentationPolicy.customerVisibleTransactions(
            page.items,
            selectedWalletID: "wallet-1",
            wallets: [wallet()]
        )

        XCTAssertEqual(visible.map(\.id), [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ])
        XCTAssertEqual(visible.map(\.customerImpactLabel), ["Money Added", "Money Deducted"])
        XCTAssertEqual(visible.map(\.customerImpactAmount), ["200000.00", "150000.00"])
        XCTAssertEqual(page.page.limit, 50)
    }

    func testGappedObjectShapedHistoryItemsFailClosed() {
        let payload = Data(
            """
            {
              "items": {
                "0": {
                  "id": "11111111-1111-4111-8111-111111111111",
                  "wallet_id": "wallet-1",
                  "reference": "KDP-0001",
                  "amount": "200000.00",
                  "totals": {"added": "200000.00", "deducted": "0.00"},
                  "currency": {"code": "UGX", "scale": "2"},
                  "type": "bank_deposit",
                  "direction": "credit",
                  "status": "completed",
                  "counterparty": null,
                  "note": null,
                  "claim": null,
                  "occurred_at": "2026-09-01T08:30:00Z"
                }
              },
              "page": {"next_cursor": null, "has_more": false, "limit": 50}
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(TransactionPage.self, from: payload))
    }

    func testAllowlistExactlyMatchesBackendCustomerHistoryContract() {
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.supportedTypes,
            Set([
                "airtime", "bank_deposit", "bank_reversal", "bank_transfer",
                "bank_withdrawal", "bill_payment", "internal_transfer",
                "internal_transfer_reversal", "merchant_escrow_release", "merchant_payment",
                "merchant_refund", "provider_reversal", "referral_reward",
                "referral_reward_reversal",
            ])
        )
    }

    func testEveryExplicitCustomerTypeSurvivesCaseAndWhitespaceNormalization() {
        let transactions = CustomerTransactionPresentationPolicy.supportedTypes
            .sorted()
            .enumerated()
            .map { index, type in
                transaction(
                    id: "customer-\(index)",
                    type: " \n\(type.uppercased())\t"
                )
            }

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(transactions)
                .map(\.id),
            transactions.map(\.id)
        )
    }

    func testInternalAndUnknownTypesFailClosedWithoutChangingCustomerOrder() {
        let transactions = [
            transaction(id: "customer-1", type: "internal_transfer"),
            transaction(id: "internal-commission", type: "institutional_commission"),
            transaction(id: "internal-revenue", type: "fee_revenue"),
            transaction(id: "internal-provider-funding", type: "operator_provider_fee_funding"),
            transaction(id: "customer-2", type: "bank_deposit"),
            transaction(id: "internal-settlement", type: "settlement_adjustment"),
            transaction(id: "future-unknown", type: "future_customer_movement"),
            transaction(id: "customer-3", type: "airtime"),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(transactions)
                .map(\.id),
            ["customer-1", "customer-2", "customer-3"]
        )

        var cachedTransactions = transactions
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedTransactions
            ),
            5
        )
        XCTAssertEqual(cachedTransactions.map(\.id), ["customer-1", "customer-2", "customer-3"])
    }

    func testModernTotalsRequireOnePositiveSideMatchingDirection() {
        let validCredit = transaction(
            id: "valid-credit",
            direction: " CREDIT ",
            amount: "150000.00",
            totals: CustomerTransactionTotals(added: "150000.00", deducted: "0")
        )
        let validDebit = transaction(
            id: "valid-debit",
            direction: "debit",
            amount: "25000",
            totals: CustomerTransactionTotals(added: "0.00", deducted: "25000")
        )
        let invalid = [
            transaction(
                id: "credit-wrong-side",
                totals: CustomerTransactionTotals(added: "0", deducted: "100")
            ),
            transaction(
                id: "debit-wrong-side",
                direction: "debit",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
            transaction(
                id: "both-positive",
                totals: CustomerTransactionTotals(added: "100", deducted: "5")
            ),
            transaction(
                id: "both-zero",
                totals: CustomerTransactionTotals(added: "0", deducted: "0")
            ),
            transaction(
                id: "public-amount-mismatch",
                amount: "101",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
            transaction(
                id: "negative",
                totals: CustomerTransactionTotals(added: "-100", deducted: "0")
            ),
            transaction(
                id: "grouped-number",
                totals: CustomerTransactionTotals(added: "1,000", deducted: "0")
            ),
            transaction(
                id: "malformed",
                totals: CustomerTransactionTotals(added: "100UGX", deducted: "0")
            ),
            transaction(
                id: "unknown-direction",
                direction: "incoming",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                [validCredit] + invalid + [validDebit]
            ).map(\.id),
            ["valid-credit", "valid-debit"]
        )
    }

    func testLegacyRowsWithoutCombinedTotalsFailClosed() {
        var rows = [
            transaction(id: "credit", direction: "credit", amount: "100.50", totals: nil),
            transaction(id: "debit", direction: " DEBIT ", amount: "75", totals: nil),
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(rows).isEmpty
        )
        XCTAssertEqual(rows[0].customerImpactAmount, "0")
        XCTAssertEqual(rows[1].customerImpactAmount, "0")
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &rows
            ),
            2
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testActivitySummaryCombinesAuthoritativeCustomerTotals() {
        let wallet = wallet()
        let transactions = [
            transaction(
                id: "credit-one",
                amount: "150000.00",
                totals: CustomerTransactionTotals(added: "150000.00", deducted: "0")
            ),
            transaction(
                id: "credit-two",
                amount: "0.25",
                totals: CustomerTransactionTotals(added: "0.25", deducted: "0")
            ),
            transaction(
                id: "debit",
                direction: "debit",
                amount: "25000.5",
                totals: CustomerTransactionTotals(added: "0", deducted: "25000.5")
            ),
            transaction(
                id: "private-leg",
                type: "institutional_commission",
                amount: "900",
                totals: CustomerTransactionTotals(added: "900", deducted: "0")
            ),
        ]

        let summary = CustomerTransactionPresentationPolicy.activitySummary(
            transactions,
            for: wallet
        )

        XCTAssertEqual(summary.addedMinorUnits, 15_000_025)
        XCTAssertEqual(summary.deductedMinorUnits, 2_500_050)
        XCTAssertEqual(
            KitMoney.formatted(
                minorUnits: summary.addedMinorUnits,
                code: wallet.currency.code,
                scale: wallet.currency.decimalScale
            ),
            "UGX 150,000.25"
        )
        XCTAssertEqual(
            KitMoney.formatted(
                minorUnits: summary.deductedMinorUnits,
                code: wallet.currency.code,
                scale: wallet.currency.decimalScale
            ),
            "UGX 25,000.5"
        )
    }

    func testSelectedWalletHistoryAndSummaryExcludeOtherWalletsAndCurrencies() {
        let selectedWallet = wallet()
        let rows = [
            transaction(id: "selected"),
            transaction(id: "other-wallet", walletId: "wallet-2"),
            transaction(
                id: "other-currency",
                currency: CurrencyDTO(code: "USD", scale: "2")
            ),
            transaction(
                id: "other-scale",
                currency: CurrencyDTO(code: "UGX", scale: "0")
            ),
        ]

        let visible = CustomerTransactionPresentationPolicy.customerVisibleTransactions(
            rows,
            for: selectedWallet
        )
        let summary = CustomerTransactionPresentationPolicy.activitySummary(
            rows,
            for: selectedWallet
        )

        XCTAssertEqual(visible.map(\.id), ["selected"])
        XCTAssertEqual(summary.addedMinorUnits, 10_000)
        XCTAssertEqual(summary.deductedMinorUnits, 0)
    }

    func testSelectedWalletProjectionFailsClosedForMissingOrStaleSelection() {
        let selectedWallet = wallet()
        let rows = [
            transaction(id: "selected"),
            transaction(id: "other-wallet", walletId: "wallet-2"),
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                rows,
                selectedWalletID: nil,
                wallets: [selectedWallet]
            ).isEmpty
        )
        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                rows,
                selectedWalletID: "stale-wallet",
                wallets: [selectedWallet]
            ).isEmpty
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                rows,
                selectedWalletID: selectedWallet.id,
                wallets: [selectedWallet]
            ).map(\.id),
            ["selected"]
        )
    }

    func testSelectedWalletProjectionUsesAuthoritativeCasingForValidBankDeposit() {
        let authoritativeWallet = wallet(id: "Wallet-Primary")
        let deposit = transaction(
            id: "bank-deposit",
            type: "bank_deposit",
            walletId: "WALLET-PRIMARY"
        )

        XCTAssertEqual(
            WalletIdentityResolver.authoritativeSelectionID(
                preferred: "wallet-primary",
                in: [authoritativeWallet]
            ),
            authoritativeWallet.id
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                [deposit],
                selectedWalletID: "wallet-primary",
                wallets: [authoritativeWallet]
            ).map(\.id),
            [deposit.id]
        )
    }

    func testAuthoritativeWalletCaseChangePreservesLastGoodHistory() {
        let cached = wallet(id: "wallet-primary")
        let authoritative = wallet(id: "WALLET-PRIMARY")
        let lastGood = transaction(
            id: "bank-deposit",
            type: "bank_deposit",
            walletId: cached.id
        )
        var state = PersistedState.empty
        state.wallets = [cached]
        state.selectedWalletId = cached.id
        state.transactions = [lastGood]

        state.replaceAuthoritativeWalletProjection(
            [authoritative],
            selectedWalletID: cached.id
        )

        XCTAssertEqual(state.selectedWalletId, authoritative.id)
        XCTAssertEqual(state.transactions, [lastGood])

        state.replaceAuthoritativeWalletProjection(
            [wallet(id: "different-wallet")],
            selectedWalletID: "different-wallet"
        )
        XCTAssertTrue(state.transactions.isEmpty)
    }

    func testNonemptyIncompatiblePagePreservesLastGoodButEmptyPageMayClear() {
        let selectedWallet = wallet()
        let validDeposit = transaction(id: "valid", type: "bank_deposit")
        let wrongWallet = transaction(
            id: "wrong-wallet",
            type: "bank_deposit",
            walletId: "wallet-2"
        )
        let invalidTotals = transaction(
            id: "invalid-totals",
            type: "bank_deposit",
            totals: CustomerTransactionTotals(added: "0", deducted: "100")
        )

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(
                for: [validDeposit],
                wallet: selectedWallet
            ),
            .replace([validDeposit])
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(
                for: [validDeposit, wrongWallet],
                wallet: selectedWallet
            ),
            .preserveLastGood
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(
                for: [invalidTotals],
                wallet: selectedWallet
            ),
            .preserveLastGood
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.pageReplacement(
                for: [],
                wallet: selectedWallet
            ),
            .replace([])
        )
    }

    func testDetailProjectionRevalidatesNavigationStateAgainstSelectedWallet() {
        let selectedWallet = wallet()
        let valid = transaction(id: "selected")
        let otherWallet = transaction(id: "other-wallet", walletId: "wallet-2")
        let internalRow = transaction(id: "internal", type: "institutional_commission")

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransaction(
                valid,
                for: selectedWallet
            )?.id,
            valid.id
        )
        XCTAssertNil(
            CustomerTransactionPresentationPolicy.customerVisibleTransaction(valid, for: nil)
        )
        XCTAssertNil(
            CustomerTransactionPresentationPolicy.customerVisibleTransaction(
                otherWallet,
                for: selectedWallet
            )
        )
        XCTAssertNil(
            CustomerTransactionPresentationPolicy.customerVisibleTransaction(
                internalRow,
                for: selectedWallet
            )
        )
    }

    func testAmountsThatCannotBeRepresentedExactlyInMinorUnitsFailClosed() {
        let rows = [
            transaction(
                id: "over-precision",
                amount: "1.001",
                totals: CustomerTransactionTotals(added: "1.001", deducted: "0")
            ),
            transaction(
                id: "over-int64",
                amount: "92233720368547758.08",
                totals: CustomerTransactionTotals(
                    added: "92233720368547758.08",
                    deducted: "0"
                )
            ),
            transaction(
                id: "invalid-scale",
                currency: CurrencyDTO(code: "UGX", scale: "invalid")
            ),
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(rows).isEmpty
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.activitySummary(rows, for: wallet()),
            .zero
        )
    }

    func testActivitySummarySaturatesInsteadOfOverflowing() {
        let rows = [
            transaction(
                id: "maximum",
                amount: "92233720368547758.07",
                totals: CustomerTransactionTotals(
                    added: "92233720368547758.07",
                    deducted: "0"
                )
            ),
            transaction(
                id: "one-more-minor-unit",
                amount: "0.01",
                totals: CustomerTransactionTotals(added: "0.01", deducted: "0")
            ),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.activitySummary(rows, for: wallet())
                .addedMinorUnits,
            Int64.max
        )
    }

    func testLegacyAliasesFailClosedEvenWhenTheyCarryPlausibleTotals() {
        let aliases = [
            "airtime_purchase", "deposit", "mobile_money", "mobile_money_collection",
            "mobile_money_payout", "mobile_money_refund", "transfer", "transfer_reversal",
            "withdrawal",
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                aliases.enumerated().map { index, type in
                    transaction(id: "legacy-\(index)", type: type)
                }
            ).isEmpty
        )
    }

    func testServiceBackedTypesSuppressStaleInstitutionalCounterpartiesAndReceipts() throws {
        let serviceTypes = CustomerTransactionPresentationPolicy.supportedTypes.subtracting(
            CustomerTransactionPresentationPolicy.customerCounterpartyTypes
        )

        for type in serviceTypes {
            let row = transaction(
                id: "service-\(type)",
                type: type,
                counterparty: Counterparty(
                    id: "institution-id",
                    name: "Kit Institutional Commission Wallet",
                    phone: "+256700000000",
                    accountNumber: "KIT-INTERNAL-COMMISSION"
                )
            )

            XCTAssertTrue(CustomerTransactionPresentationPolicy.isCustomerVisible(row), type)
            XCTAssertNil(row.customerCounterparty, type)

            let receipt = try XCTUnwrap(
                KitReceiptContent.from(transaction: row, senderName: "Kit Customer"),
                type
            )
            let renderedText = ([receipt.directionLine, receipt.shareMessage]
                + receipt.rows.flatMap { [$0.label, $0.value] })
                .joined(separator: " ")
                .lowercased()
            XCTAssertFalse(renderedText.contains("institution"), type)
            XCTAssertFalse(renderedText.contains("commission"), type)
            XCTAssertFalse(renderedText.contains("kit-internal"), type)
        }

        var cachedRows = serviceTypes.sorted().enumerated().map { index, type in
            transaction(
                id: "cached-service-\(index)",
                type: type,
                counterparty: Counterparty(
                    id: "institution-id",
                    name: "Kit Institutional Commission Wallet",
                    phone: "+256700000000",
                    accountNumber: "KIT-INTERNAL-COMMISSION"
                )
            )
        }
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedRows
            ),
            serviceTypes.count
        )
        XCTAssertTrue(cachedRows.allSatisfy { $0.counterparty == nil })
    }

    func testDirectTransferKeepsItsCustomerCounterparty() throws {
        let row = transaction(
            id: "direct-transfer",
            type: "internal_transfer",
            counterparty: Counterparty(
                id: "recipient-id",
                name: "Namisi Emmanuel",
                phone: "+256700000001",
                accountNumber: "KIT-CUSTOMER"
            )
        )

        XCTAssertEqual(row.customerCounterparty?.id, "recipient-id")
        XCTAssertEqual(row.customerCounterparty?.name, "Namisi Emmanuel")

        let receipt = try XCTUnwrap(
            KitReceiptContent.from(transaction: row, senderName: "Kit Customer")
        )
        XCTAssertEqual(receipt.directionLine, "Received from Namisi Emmanuel")
        XCTAssertEqual(
            receipt.rows.first(where: { $0.label == "From" })?.value,
            "Namisi Emmanuel"
        )

        var cachedRows = [row]
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedRows
            ),
            0
        )
        XCTAssertEqual(cachedRows.first?.counterparty, row.counterparty)
    }

    private func transaction(
        id: String,
        type: String = "internal_transfer",
        direction: String = "credit",
        amount: String = "100",
        totals: CustomerTransactionTotals? = CustomerTransactionTotals(
            added: "100",
            deducted: "0"
        ),
        walletId: String = "wallet-1",
        currency: CurrencyDTO = CurrencyDTO(code: "UGX", scale: "2"),
        counterparty: Counterparty? = nil
    ) -> WalletTransaction {
        WalletTransaction(
            id: id,
            walletId: walletId,
            reference: "REF-\(id)",
            amount: amount,
            totals: totals,
            currency: currency,
            type: type,
            direction: direction,
            status: "completed",
            counterparty: counterparty,
            note: nil,
            occurredAt: "2026-09-01T12:00:00Z"
        )
    }

    private func wallet(id: String = "wallet-1") -> Wallet {
        Wallet(
            id: id,
            name: "Primary wallet",
            accountNumber: "KIT-1000",
            accountType: "personal",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            balances: WalletBalances(available: "0", ledger: "0"),
            status: "active",
            isPrimary: true
        )
    }
}
