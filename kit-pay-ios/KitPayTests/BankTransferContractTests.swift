import Foundation
import XCTest
@testable import KitPay

final class BankTransferContractTests: XCTestCase {
    func testBankCatalogDecodesTransferAndVerificationCapabilities() throws {
        let response: BankListDTO = try decode(
            """
            {
              "items":[{
                "id":"11111111-1111-4111-8111-111111111111",
                "code":"040147",
                "name":"Stanbic Bank Uganda",
                "country_code":"UG",
                "currency":"UGX",
                "capabilities":{
                  "account_verification":true,
                  "deposits":false,
                  "withdrawals":true,
                  "transfers":true
                }
              }]
            }
            """
        )

        let bank = try XCTUnwrap(response.items?.first)
        XCTAssertEqual(bank.code, "040147")
        XCTAssertEqual(bank.countryCode, "UG")
        XCTAssertEqual(bank.currency, "UGX")
        XCTAssertTrue(bank.canVerifyAccount)
        XCTAssertTrue(bank.canTransfer)
    }

    func testSuccessfulBankCatalogDecodesLegacyNumericallyIndexedItems() throws {
        let envelope: APIEnvelope<BankListDTO> = try decode(
            """
            {
              "ok":true,
              "data":{
                "items":{
                  "1":{
                    "id":"11111111-1111-4111-8111-111111111111",
                    "code":"040147",
                    "name":"Stanbic Bank Uganda",
                    "country_code":"UG",
                    "currency":"UGX",
                    "capabilities":{"account_verification":true,"transfers":true}
                  },
                  "3":{
                    "id":"22222222-2222-4222-8222-222222222222",
                    "code":"010147",
                    "name":"Centenary Bank",
                    "country_code":"UG",
                    "currency":"UGX",
                    "capabilities":{"account_verification":true,"transfers":true}
                  }
                }
              },
              "error":null,
              "meta":null
            }
            """
        )

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data?.items?.map(\.code), ["040147", "010147"])
    }

    func testBankCatalogRejectsArbitraryObjectItems() {
        let malformed =
            """
            {
              "items":{
                "featured":{
                  "id":"11111111-1111-4111-8111-111111111111",
                  "code":"040147",
                  "name":"Stanbic Bank Uganda",
                  "country_code":"UG",
                  "currency":"UGX",
                  "capabilities":{"account_verification":true,"transfers":true}
                }
              }
            }
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BankListDTO.self,
                from: Data(malformed.utf8)
            )
        )
    }

    func testBankCapabilitiesFailClosedAndRequireWallets() throws {
        let available: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"2"},"features":{
              "wallets":true,"bank_transfers":true
            }}
            """
        )
        let missingWallet: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"2"},"features":{
              "bank_transfers":true
            }}
            """
        )
        let unknown: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"2"},"features":{
              "wallets":true,"bank_transfers":null
            }}
            """
        )

        XCTAssertTrue(available.enablesBankTransfers)
        XCTAssertFalse(missingWallet.enablesBankTransfers)
        XCTAssertFalse(unknown.enablesBankTransfers)
    }

    func testBankDepositCapabilityFailsClosedAndRemainsIndependentFromOutboundTransfers() throws {
        let depositsOnly: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"0"},"features":{
              "wallets":true,"bank_deposits":true,"bank_transfers":false
            }}
            """
        )
        let missingWallet: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"0"},"features":{"bank_deposits":true}}
            """
        )
        let unknown: CapabilitiesDTO = try decode(
            """
            {"currency":{"code":"UGX","scale":"0"},"features":{
              "wallets":true,"bank_deposits":null
            }}
            """
        )

        XCTAssertTrue(depositsOnly.enablesBankDeposits)
        XCTAssertFalse(depositsOnly.enablesBankTransfers)
        XCTAssertFalse(missingWallet.enablesBankDeposits)
        XCTAssertFalse(unknown.enablesBankDeposits)
    }

    func testFundingAccountAndDepositResponseDecodeWithoutABeneficiary() throws {
        let response: BankDepositRequestDTO = try decode(bankDepositJSON())

        XCTAssertEqual(response.walletId, "33333333-3333-4333-8333-333333333333")
        XCTAssertEqual(response.fundingAccount.accountName, "KIT POS UGANDA LIMITED")
        XCTAssertEqual(response.fundingAccount.accountNumber, "0100012345678")
        XCTAssertEqual(response.reference, "K7P2-9QMX-4R8C-T6WA")
        XCTAssertTrue(response.acceptsProof)
        XCTAssertFalse(response.isTerminal)
        XCTAssertNil(response.proof)
    }

    func testDepositCreationContractNeverContainsABeneficiary() throws {
        let request = CreateBankDepositRequest(
            walletId: "33333333-3333-4333-8333-333333333333",
            fundingAccountId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amount: "1856.84",
            note: "Bank transfer"
        )
        let body = try jsonObject(request)

        XCTAssertEqual(body["wallet_id"] as? String, request.walletId)
        XCTAssertEqual(body["funding_account_id"] as? String, request.fundingAccountId)
        XCTAssertEqual(body["amount"] as? String, "1856.84")
        XCTAssertEqual(Set(body.keys), ["wallet_id", "funding_account_id", "amount", "note"])
        XCTAssertNil(body["beneficiary_id"])

        let proof = try jsonObject(AttachBankDepositProofRequest(
            mediaAssetId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ))
        XCTAssertEqual(Set(proof.keys), ["media_asset_id"])
        XCTAssertNil(proof["beneficiary_id"])
    }

    func testDepositAmountsTrimTrailingZerosWithoutChangingValue() {
        XCTAssertEqual(BankDepositMoney.apiAmount("1,856.840", scale: 3), "1856.84")
        XCTAssertEqual(BankDepositMoney.apiAmount("1,768.80", scale: 2), "1768.8")
        XCTAssertEqual(BankDepositMoney.apiAmount("1000.00", scale: 2), "1000")
        XCTAssertEqual(BankDepositMoney.apiAmount("0001.20", scale: 2), "1.2")
        XCTAssertNil(BankDepositMoney.apiAmount("0.00", scale: 2))
        XCTAssertNil(BankDepositMoney.apiAmount("1.001", scale: 2))
        XCTAssertNil(BankDepositMoney.apiAmount("UGX 500", scale: 0))
    }

    func testHumanReadableDepositReferenceRequiresFourUppercaseGroups() {
        XCTAssertTrue(BankDepositReferencePolicy.isValid("K7P2-9QMX-4R8C-T6WA"))
        XCTAssertFalse(BankDepositReferencePolicy.isValid("k7p2-9qmx-4r8c-t6wa"))
        XCTAssertFalse(BankDepositReferencePolicy.isValid("K7P2-9QMX-4R8C"))
        XCTAssertFalse(BankDepositReferencePolicy.isValid("7777-9999-4444-8888"))
        XCTAssertFalse(BankDepositReferencePolicy.isValid("ABCD-EFGH-JKLM-NPQR"))
    }

    func testDepositProofPolicyAcceptsOnlySupportedBoundedFiles() {
        XCTAssertTrue(BankDepositProofUploadPolicy.accepts(
            data: Data([0xFF, 0xD8, 0xFF]),
            filename: "receipt.jpg",
            mimeType: "image/jpeg"
        ))
        XCTAssertFalse(BankDepositProofUploadPolicy.accepts(
            data: Data(),
            filename: "receipt.jpg",
            mimeType: "image/jpeg"
        ))
        XCTAssertFalse(BankDepositProofUploadPolicy.accepts(
            data: Data([0x01]),
            filename: "receipt.heic",
            mimeType: "image/heic"
        ))
    }

    func testAccountVerificationRequestUsesNormalizedBankContract() throws {
        let account = try XCTUnwrap(BankAccountNumber.apiValue(from: " 0012-34 ab 5678 "))
        let request = CreateBankAccountVerificationRequest(
            bankId: "11111111-1111-4111-8111-111111111111",
            accountNumber: account
        )

        let object = try jsonObject(request)

        XCTAssertEqual(account, "001234AB5678")
        XCTAssertEqual(object["bank_id"] as? String, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(object["account_number"] as? String, "001234AB5678")
        XCTAssertEqual(Set(object.keys), ["bank_id", "account_number"])
        XCTAssertNil(BankAccountNumber.apiValue(from: "123"))
    }

    func testBeneficiaryRequestUsesVerifiedAccountIdentity() throws {
        let request = CreateBankBeneficiaryRequest(
            verificationId: "22222222-2222-4222-8222-222222222222",
            kind: "third_party",
            label: "ExampleContact"
        )

        let object = try jsonObject(request)

        XCTAssertEqual(object["verification_id"] as? String, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(object["kind"] as? String, "third_party")
        XCTAssertEqual(object["label"] as? String, "ExampleContact")
        XCTAssertEqual(Set(object.keys), ["verification_id", "kind", "label"])
    }

    func testBeneficiaryRailPolicyKeepsMobileMoneyDestinationsOffTheBankSurface() {
        let bank = BankDTO(
            id: "11111111-1111-4111-8111-111111111111",
            code: "040147",
            name: "Stanbic Bank Uganda",
            countryCode: "UG",
            currency: "UGX",
            capabilities: ["account_verification": true, "transfers": true]
        )
        let mobileMoneyNetwork = BankDTO(
            id: "77777777-7777-4777-8777-777777777777",
            code: "MTN",
            name: "MTN Mobile Money",
            countryCode: "UG",
            currency: "UGX",
            capabilities: [
                "account_verification": true,
                "transfers": true,
                "collections": true,
                "payouts": true,
            ]
        )
        let mixedRailSignals = BankDTO(
            id: "88888888-8888-4888-8888-888888888888",
            code: "010147",
            name: "Centenary Bank",
            countryCode: "UG",
            currency: "UGX",
            capabilities: ["transfers": true, "payouts": true]
        )
        let transfersDisabled = BankDTO(
            id: "99999999-9999-4999-8999-999999999999",
            code: "030233",
            name: "Deposit-only bank",
            countryCode: "UG",
            currency: "UGX",
            capabilities: ["account_verification": true]
        )

        XCTAssertTrue(BankBeneficiaryRailPolicy.isBankRailDestination(bank))
        XCTAssertFalse(BankBeneficiaryRailPolicy.isBankRailDestination(mobileMoneyNetwork))
        XCTAssertFalse(BankBeneficiaryRailPolicy.isBankRailDestination(mixedRailSignals))
        XCTAssertFalse(BankBeneficiaryRailPolicy.isBankRailDestination(transfersDisabled))

        XCTAssertEqual(
            BankBeneficiaryRailPolicy.bankRailBanks([
                mobileMoneyNetwork, bank, mixedRailSignals, transfersDisabled,
            ]).map(\.id),
            [bank.id]
        )

        XCTAssertEqual(
            BankBeneficiaryRailPolicy.bankRailBeneficiaries([
                bankBeneficiary(id: "beneficiary-mobile", bank: mobileMoneyNetwork),
                bankBeneficiary(id: "beneficiary-bank", bank: bank),
                bankBeneficiary(id: "beneficiary-ambiguous", bank: mixedRailSignals),
            ]).map(\.id),
            ["beneficiary-bank"]
        )
    }

    func testWholeUGXAmountNeverRoundsOrSendsDecimals() {
        XCTAssertEqual(BankTransferMoney.wholeUGXAmount("1,250"), "1250")
        XCTAssertEqual(BankTransferMoney.wholeUGXAmount("000500"), "500")
        XCTAssertEqual(BankTransferMoney.wholeUGXAmount(" 10 000 "), "10000")
        XCTAssertNil(BankTransferMoney.wholeUGXAmount("0"))
        XCTAssertNil(BankTransferMoney.wholeUGXAmount("500.00"))
        XCTAssertNil(BankTransferMoney.wholeUGXAmount("500.5"))
        XCTAssertNil(BankTransferMoney.wholeUGXAmount("UGX 500"))
        XCTAssertNil(BankTransferMoney.wholeUGXAmount("-500"))
        XCTAssertNil(BankTransferMoney.editableWholeUGXInput("500.50"))
        XCTAssertEqual(BankTransferMoney.editableWholeUGXInput("1,250"), "1250")
        XCTAssertNil(BankTransferMoney.transferableWholeUGXAmount("19999"))
        XCTAssertEqual(BankTransferMoney.transferableWholeUGXAmount("20,000"), "20000")
    }

    func testTransferQuoteRequestDefaultsToExplicitSenderFeeAndUsesWholeAmount() throws {
        let request = CreateBankTransferQuoteRequest(
            walletId: "33333333-3333-4333-8333-333333333333",
            beneficiaryId: "44444444-4444-4444-8444-444444444444",
            amount: "5000",
            feeMode: .senderAbsorbs
        )

        let body = try jsonObject(request)

        XCTAssertEqual(body["wallet_id"] as? String, request.walletId)
        XCTAssertEqual(body["beneficiary_id"] as? String, request.beneficiaryId)
        XCTAssertEqual(body["amount"] as? String, "5000")
        XCTAssertEqual(body["fee_mode"] as? String, "sender_absorbs")
        XCTAssertEqual(Set(body.keys), ["wallet_id", "beneficiary_id", "amount", "fee_mode"])
    }

    func testBeneficiaryCoveredTransferUsesEnteredAmountAsExactWalletDebit() throws {
        let request = CreateBankTransferQuoteRequest(
            walletId: "33333333-3333-4333-8333-333333333333",
            beneficiaryId: "44444444-4444-4444-8444-444444444444",
            amount: "20000",
            feeMode: .beneficiaryAbsorbs
        )
        let body = try jsonObject(request)
        XCTAssertEqual(body["fee_mode"] as? String, "recipient_absorbs")

        let quote = explicitSplitQuote(feeMode: .beneficiaryAbsorbs)
        XCTAssertEqual(quote.enteredAmount, "11000.00")
        XCTAssertEqual(quote.recipientAmount, "5000.00")
        XCTAssertEqual(quote.processingFee, "6000.00")
        XCTAssertEqual(quote.customerDebit, "11000.00")
        XCTAssertEqual(quote.kitDebit, "0.00")
        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertTrue(quote.hasValidStepUpBinding)
    }

    func testQuotedTransferSubmissionContainsOnlyQuoteId() throws {
        let request = CreateQuotedBankTransferRequest(
            quoteId: "66666666-6666-4666-8666-666666666666"
        )
        let body = try jsonObject(request)

        XCTAssertEqual(body["quote_id"] as? String, request.quoteId)
        XCTAssertEqual(Set(body.keys), ["quote_id"])
        XCTAssertNil(body["wallet_id"])
        XCTAssertNil(body["beneficiary_id"])
        XCTAssertNil(body["amount"])
    }

    func testBankTransferQuoteDecodesExactFeeReviewAndStepUpIntent() throws {
        let quote = try sampleQuote()

        XCTAssertEqual(quote.action, "transfer")
        XCTAssertEqual(quote.operationType, BankTransferContract.operationType)
        XCTAssertEqual(quote.feeMode, .senderAbsorbs)
        XCTAssertEqual(quote.stepUp.purpose, BankTransferContract.purpose)
        XCTAssertEqual(quote.stepUp.intent["quote_id"], quote.id)
        XCTAssertEqual(quote.stepUp.intent["customer_debit"], quote.customerDebit)
        XCTAssertEqual(quote.stepUp.intent.count, 16)
        XCTAssertTrue(quote.scheduleVerified)
        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertTrue(quote.hasValidStepUpBinding)
        XCTAssertFalse(quote.isExpired)
    }

    func testBankTransferQuoteRejectsExtraOrWrongStepUpBinding() throws {
        let json = sampleQuoteJSON().replacingOccurrences(
            of: "\"intent\":{",
            with: "\"intent\":{\"unexpected\":\"value\","
        )
        let quote: BankTransferQuoteDTO = try decode(json)

        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertFalse(quote.hasValidStepUpBinding)
    }

    func testBankTariffBindsProviderAndKitFeeSplitWithoutDoublingProviderExposure() throws {
        let quote = explicitSplitQuote(feeMode: .senderAbsorbs)

        XCTAssertEqual(quote.processingFee, "6000.00")
        XCTAssertEqual(quote.providerFee, "3000.00")
        XCTAssertEqual(quote.kitFee, "3000.00")
        XCTAssertEqual(quote.providerFeeCap, "3000.00")
        XCTAssertEqual(quote.maximumProviderTotal, "8000.00")
        XCTAssertEqual(quote.customerDebit, "11000.00")
        XCTAssertEqual(quote.stepUp.intent.count, 18)
        XCTAssertTrue(quote.hasConsistentAmounts)
        XCTAssertTrue(quote.hasValidStepUpBinding)

        let decoded: BankTransferQuoteDTO = try decode(explicitSplitQuoteJSON())
        XCTAssertEqual(decoded.providerFee, "3000.00")
        XCTAssertEqual(decoded.kitFee, "3000.00")
        XCTAssertTrue(decoded.hasConsistentAmounts)
        XCTAssertTrue(decoded.hasValidStepUpBinding)

        let incomplete: BankTransferQuoteDTO = try decode(
            explicitSplitQuoteJSON().replacingOccurrences(
                of: "\"kit_fee\":\"3000.00\",",
                with: ""
            )
        )
        XCTAssertFalse(incomplete.hasConsistentAmounts)
        XCTAssertFalse(incomplete.hasValidStepUpBinding)

        let pricing = BankTransferOutboundPricingDTO(
            feeMode: .senderAbsorbs,
            recipientAmount: quote.recipientAmount,
            processingFee: quote.processingFee,
            providerFee: quote.providerFee,
            kitFee: quote.kitFee,
            providerFeeCap: quote.providerFeeCap,
            maximumProviderTotal: quote.maximumProviderTotal,
            customerDebit: quote.customerDebit,
            kitDebit: quote.kitDebit,
            scheduleVersion: quote.scheduleVersion,
            actualProviderFee: nil,
            actualProviderTotal: nil
        )
        XCTAssertTrue(pricing.hasConsistentAmounts)
        XCTAssertTrue(pricing.matches(quote))

        let covered = explicitSplitQuote(feeMode: .kitCovers)
        XCTAssertEqual(covered.customerDebit, "5000.00")
        XCTAssertEqual(covered.kitDebit, "3000.00")
        XCTAssertTrue(covered.hasConsistentAmounts)
        XCTAssertTrue(covered.hasValidStepUpBinding)

        XCTAssertFalse(BankTransferMoney.outboundAmountsReconcile(
            feeMode: .senderAbsorbs,
            recipientAmount: "5000.00",
            processingFee: "6000.00",
            providerFee: "4000.00",
            kitFee: "3000.00",
            providerFeeCap: "4000.00",
            maximumProviderTotal: "9000.00",
            customerDebit: "11000.00",
            kitDebit: "0.00"
        ))
    }

    func testOperationReceiptDecodesQuoteBoundOutboundPricingWithoutGuessingSuccess() throws {
        let operation: BankingOperationDTO = try decode(
            """
            {
              "id":"55555555-5555-4555-8555-555555555555",
              "reference":"BNK-01ABC",
              "type":"bank_transfer",
              "direction":"outbound",
              "status":"pending",
              "submission_stage":"awaiting_provider",
              "bank_id":"11111111-1111-4111-8111-111111111111",
              "beneficiary_id":"44444444-4444-4444-8444-444444444444",
              "wallet_id":"33333333-3333-4333-8333-333333333333",
              "amount":"5000.00",
              "outbound_quote_id":"66666666-6666-4666-8666-666666666666",
              "outbound_pricing":{
                "fee_mode":"sender_absorbs",
                "recipient_amount":"5000.00",
                "processing_fee":"5000.00",
                "provider_fee_cap":"5000.00",
                "maximum_provider_total":"10000.00",
                "customer_debit":"10000.00",
                "kit_debit":"0.00",
                "schedule_version":"kit-pos-v8-2026-08-18",
                "actual_provider_fee":null,
                "actual_provider_total":null
              },
              "fee_quote_id":null,
              "fee_mode":null,
              "requested_amount":null,
              "provider_fee":null,
              "platform_fee":null,
              "rounding_adjustment":null,
              "total_fees":null,
              "net_amount":null,
              "currency":{"code":"UGX","scale":"2"},
              "provider_reference":"ruka-123",
              "wallet_transaction_id":null,
              "reversal_transaction_id":null,
              "failure":null,
              "created_at":"2026-08-18T10:40:31Z",
              "completed_at":null
            }
            """
        )

        XCTAssertEqual(operation.type, "bank_transfer")
        XCTAssertEqual(operation.submissionStage, "awaiting_provider")
        XCTAssertFalse(operation.isTerminal)
        XCTAssertFalse(operation.isSuccessful)
        XCTAssertEqual(operation.outboundQuoteId, "66666666-6666-4666-8666-666666666666")
        XCTAssertEqual(operation.outboundPricing?.feeMode, .senderAbsorbs)
        XCTAssertEqual(operation.outboundPricing?.customerDebit, "10000.00")
        XCTAssertTrue(operation.outboundPricing?.hasConsistentAmounts == true)
        XCTAssertTrue(BankTransferMoney.operationAmount(operation.amount, matchesWholeUGX: "5000"))
        let quote = try sampleQuote()
        XCTAssertTrue(operation.hasSameOutboundBinding(as: quote))
    }

    func testKitCoversPricingRequiresExactServiceDebit() {
        XCTAssertTrue(BankTransferMoney.outboundAmountsReconcile(
            feeMode: .kitCovers,
            recipientAmount: "5000.00",
            processingFee: "5000.00",
            providerFeeCap: "5000.00",
            maximumProviderTotal: "10000.00",
            customerDebit: "5000.00",
            kitDebit: "5000.00"
        ))
        XCTAssertFalse(BankTransferMoney.outboundAmountsReconcile(
            feeMode: .kitCovers,
            recipientAmount: "5000.00",
            processingFee: "5000.00",
            providerFeeCap: "5000.00",
            maximumProviderTotal: "10000.00",
            customerDebit: "5000.00",
            kitDebit: "0.00"
        ))
    }

    func testIdempotencyKeysMeetBankingHeaderContractAndDifferByAttempt() {
        let first = BankTransferIdempotency.key(
            prefix: "ios-bank-transfer",
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        )
        let second = BankTransferIdempotency.key(
            prefix: "ios-bank-transfer",
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        )

        XCTAssertEqual(first, "ios-bank-transfer-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 16)
        XCTAssertLessThanOrEqual(first.count, 128)
        XCTAssertNotNil(first.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression))
    }

    func testInvalidBankActionPayloadsUseContextSpecificCustomerCopy() {
        let expected: [BankTransferActionErrorContext: String] = [
            .accountVerification:
                "Kit Pay could not confirm the bank account verification response. No beneficiary was saved. Please try again.",
            .beneficiarySave:
                "Kit Pay could not confirm that this beneficiary was saved. Refresh your beneficiaries before trying again.",
            .quoteReview:
                "We couldn't load the latest transaction fee and total for this bank transfer. Nothing was submitted. Please review the amounts and try again.",
            .transferApproval:
                "Kit Pay could not confirm this bank transfer approval. Nothing was submitted. Please approve again.",
            .transferSubmission:
                "Kit Pay could not confirm the bank transfer response. Check recent bank transfers before retrying.",
        ]

        for status in [200, 201, 202] {
            for context in BankTransferActionErrorContext.allCases {
                let message = BankTransferActionErrorCopy.message(
                    for: APIClientError.invalidPayload(status: status),
                    context: context
                )
                guard let expectedMessage = expected[context] else {
                    XCTFail("Missing expected copy for \(context).")
                    continue
                }

                XCTAssertEqual(message, expectedMessage)
                XCTAssertFalse(message.localizedCaseInsensitiveContains("unreadable"))
                XCTAssertNil(message.range(of: #"\bHTTP\s+\d{3}\b"#, options: .regularExpression))
            }
        }

        XCTAssertTrue(expected[.quoteReview]?.contains("Nothing was submitted") == true)
        XCTAssertTrue(expected[.transferApproval]?.contains("Nothing was submitted") == true)
        XCTAssertTrue(
            expected[.transferSubmission]?.contains(
                "Check recent bank transfers before retrying"
            ) == true
        )
        XCTAssertEqual(
            BankTransferActionErrorCopy.transferContext(submissionStarted: false),
            .transferApproval
        )
        XCTAssertEqual(
            BankTransferActionErrorCopy.transferContext(submissionStarted: true),
            .transferSubmission
        )
    }

    func testGenericInvalidPayloadCopyDoesNotExposeTransportDiagnostics() {
        let message = APIClientError.invalidPayload(status: 200).localizedDescription

        XCTAssertEqual(
            message,
            "Kit Pay could not refresh this information. Please try again."
        )
        XCTAssertFalse(message.localizedCaseInsensitiveContains("unreadable"))
        XCTAssertNil(message.range(of: #"\bHTTP\s+\d{3}\b"#, options: .regularExpression))
    }

    func testBankActionErrorCopyKeepsFeeAndProviderMessagePolicies() {
        let feeError = APIErrorPayload(
            code: "BANK_OUTBOUND_FEE_FUNDING_REQUIRED",
            message: "Funding required."
        )
        XCTAssertEqual(
            BankTransferActionErrorCopy.message(
                for: feeError,
                context: .quoteReview,
                feeMode: .kitCovers
            ),
            "This fee treatment is unavailable. Review a transfer with the fee covered by you or by the beneficiary."
        )

        let providerError = APIErrorPayload(
            code: "PROVIDER_UNAVAILABLE",
            message: "RukaPay is temporarily unavailable."
        )
        XCTAssertEqual(
            BankTransferActionErrorCopy.message(
                for: providerError,
                context: .accountVerification
            ),
            "Kit Pay's payment service is temporarily unavailable."
        )
    }

    @MainActor
    func testAuxiliaryLoadFailuresDoNotHideAvailableBanks() throws {
        let bankList = try bankListFixture()
        let model = BankTransferViewModel()
        let unreadableBeneficiaries = APIClientError.invalidPayload(status: 200)
        let unreadableOperations = APIClientError.invalidPayload(status: 200)

        model.applyLoadResults(BankTransferLoadResults(
            country: "UG",
            bankCatalog: .success(bankList),
            beneficiaries: .failure(unreadableBeneficiaries),
            operations: .failure(unreadableOperations)
        ))

        XCTAssertEqual(model.banks.map(\.name), ["Stanbic Bank Uganda"])
        XCTAssertNil(model.bankCatalogErrorMessage)
        XCTAssertNotNil(model.beneficiaryLoadErrorMessage)
        XCTAssertNotNil(model.operationLoadErrorMessage)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testFailedCatalogRefreshKeepsLastKnownBanks() throws {
        let bankList = try bankListFixture()
        let model = BankTransferViewModel()
        let emptyBeneficiaries = BankBeneficiaryListDTO(items: [])
        let emptyOperations = BankingOperationListDTO(items: [])
        model.applyLoadResults(BankTransferLoadResults(
            country: "UG",
            bankCatalog: .success(bankList),
            beneficiaries: .success(emptyBeneficiaries),
            operations: .success(emptyOperations)
        ))

        model.applyLoadResults(BankTransferLoadResults(
            country: "UG",
            bankCatalog: .failure(APIClientError.invalidPayload(status: 200)),
            beneficiaries: .success(emptyBeneficiaries),
            operations: .success(emptyOperations)
        ))

        XCTAssertEqual(model.banks.map(\.code), ["040147"])
        XCTAssertNotNil(model.bankCatalogErrorMessage)
        XCTAssertNil(model.beneficiaryLoadErrorMessage)
        XCTAssertNil(model.operationLoadErrorMessage)
    }

    @MainActor
    func testFailedCatalogForDifferentCountryClearsOldBanks() throws {
        let bankList = try bankListFixture()
        let model = BankTransferViewModel()
        let emptyBeneficiaries = BankBeneficiaryListDTO(items: [])
        let emptyOperations = BankingOperationListDTO(items: [])
        model.applyLoadResults(BankTransferLoadResults(
            country: "UG",
            bankCatalog: .success(bankList),
            beneficiaries: .success(emptyBeneficiaries),
            operations: .success(emptyOperations)
        ))

        model.applyLoadResults(BankTransferLoadResults(
            country: "KE",
            bankCatalog: .failure(APIClientError.invalidPayload(status: 200)),
            beneficiaries: .success(emptyBeneficiaries),
            operations: .success(emptyOperations)
        ))

        XCTAssertTrue(model.banks.isEmpty)
        XCTAssertNotNil(model.bankCatalogErrorMessage)
    }

    func testBankLoadCoalescesSameCountryAndAppliesCurrentOwnedRequest() {
        let first = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let second = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

        XCTAssertTrue(BankTransferLoadRequestPolicy.shouldStart(isCancelled: false))
        XCTAssertFalse(BankTransferLoadRequestPolicy.shouldStart(isCancelled: true))
        XCTAssertTrue(BankTransferLoadRequestPolicy.shouldJoin(
            activeCountry: "UG",
            requestedCountry: "UG"
        ))
        XCTAssertFalse(BankTransferLoadRequestPolicy.shouldJoin(
            activeCountry: "UG",
            requestedCountry: "KE"
        ))
        XCTAssertFalse(BankTransferLoadRequestPolicy.shouldJoin(
            activeCountry: nil,
            requestedCountry: "UG"
        ))
        XCTAssertTrue(BankTransferLoadRequestPolicy.shouldApply(
            requestID: second,
            currentRequestID: second
        ))
        XCTAssertFalse(BankTransferLoadRequestPolicy.shouldApply(
            requestID: first,
            currentRequestID: second
        ))
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func bankBeneficiary(id: String, bank: BankDTO) -> BankBeneficiaryDTO {
        BankBeneficiaryDTO(
            id: id,
            kind: "third_party",
            label: "ExampleContact",
            bank: bank,
            accountName: "EXAMPLE CONTACT",
            accountNumberMasked: "••••5678",
            status: "active"
        )
    }

    private func bankListFixture() throws -> BankListDTO {
        try decode(
            """
            {
              "items":[{
                "id":"11111111-1111-4111-8111-111111111111",
                "code":"040147",
                "name":"Stanbic Bank Uganda",
                "country_code":"UG",
                "currency":"UGX",
                "capabilities":{"account_verification":true,"transfers":true}
              }]
            }
            """
        )
    }

    private func bankDepositJSON() -> String {
        """
        {
          "id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          "reference":"K7P2-9QMX-4R8C-T6WA",
          "wallet_id":"33333333-3333-4333-8333-333333333333",
          "amount":"1856.84",
          "currency":{"code":"UGX","scale":"2"},
          "status":"awaiting_proof",
          "source":"customer",
          "funding_account":{
            "id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "label":"Kit Pay collections",
            "bank":{
              "id":"11111111-1111-4111-8111-111111111111",
              "name":"Stanbic Bank Uganda",
              "code":"040147",
              "country_code":"UG"
            },
            "account_name":"KIT POS UGANDA LIMITED",
            "account_number":"0100012345678",
            "account_number_masked":"••••5678",
            "branch_name":"Garden City",
            "branch_code":null,
            "swift_code":"SBICUGKX",
            "instructions":"Use the exact Kit Pay reference.",
            "currency":"UGX",
            "status":"active"
          },
          "proof":null,
          "bank_transaction_reference":null,
          "customer_note":null,
          "rejection":null,
          "expires_at":"2099-08-31T12:00:00Z",
          "created_at":"2026-08-26T12:00:00Z",
          "proof_submitted_at":null,
          "completed_at":null
        }
        """
    }

    private func sampleQuote() throws -> BankTransferQuoteDTO {
        try decode(sampleQuoteJSON())
    }

    private func explicitSplitQuote(feeMode: BankTransferFeeMode) -> BankTransferQuoteDTO {
        let customerDebit = feeMode == .kitCovers ? "5000.00" : "11000.00"
        let kitDebit = feeMode == .kitCovers ? "3000.00" : "0.00"
        let common = [
            "action": "transfer",
            "operation_type": BankTransferContract.operationType,
            "quote_id": "66666666-6666-4666-8666-666666666667",
            "wallet_id": "33333333-3333-4333-8333-333333333333",
            "beneficiary_id": "44444444-4444-4444-8444-444444444444",
            "bank_id": "11111111-1111-4111-8111-111111111111",
            "bank_code": "040147",
            "fee_mode": feeMode.rawValue,
            "recipient_amount": "5000.00",
            "processing_fee": "6000.00",
            "provider_fee": "3000.00",
            "kit_fee": "3000.00",
            "provider_fee_cap": "3000.00",
            "maximum_provider_total": "8000.00",
            "customer_debit": customerDebit,
            "kit_debit": kitDebit,
            "schedule_version": "kit-bank-v1-2026-08-19",
            "currency": "UGX",
        ]
        return BankTransferQuoteDTO(
            id: "66666666-6666-4666-8666-666666666667",
            action: "transfer",
            operationType: BankTransferContract.operationType,
            feeMode: feeMode,
            walletId: "33333333-3333-4333-8333-333333333333",
            beneficiaryId: "44444444-4444-4444-8444-444444444444",
            bank: BankTransferQuoteBankDTO(
                id: "11111111-1111-4111-8111-111111111111",
                code: "040147",
                name: "Stanbic Bank Uganda"
            ),
            recipientAmount: "5000.00",
            processingFee: "6000.00",
            providerFee: "3000.00",
            kitFee: "3000.00",
            providerFeeCap: "3000.00",
            maximumProviderTotal: "8000.00",
            customerDebit: customerDebit,
            kitDebit: kitDebit,
            scheduleVersion: "kit-bank-v1-2026-08-19",
            scheduleVerified: true,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            expiresAt: "2099-08-18T23:59:59Z",
            stepUp: BankTransferQuoteStepUpDTO(
                purpose: BankTransferContract.purpose,
                intent: common
            )
        )
    }

    private func explicitSplitQuoteJSON() -> String {
        sampleQuoteJSON()
            .replacingOccurrences(
                of: "\"processing_fee\":\"5000.00\",",
                with: "\"processing_fee\":\"6000.00\",\"provider_fee\":\"3000.00\",\"kit_fee\":\"3000.00\","
            )
            .replacingOccurrences(
                of: "\"provider_fee_cap\":\"5000.00\"",
                with: "\"provider_fee_cap\":\"3000.00\""
            )
            .replacingOccurrences(
                of: "\"maximum_provider_total\":\"10000.00\"",
                with: "\"maximum_provider_total\":\"8000.00\""
            )
            .replacingOccurrences(
                of: "\"customer_debit\":\"10000.00\"",
                with: "\"customer_debit\":\"11000.00\""
            )
    }

    private func sampleQuoteJSON() -> String {
        """
            {
              "id":"66666666-6666-4666-8666-666666666666",
              "action":"transfer",
              "operation_type":"bank_transfer",
              "fee_mode":"sender_absorbs",
              "wallet_id":"33333333-3333-4333-8333-333333333333",
              "beneficiary_id":"44444444-4444-4444-8444-444444444444",
              "bank":{"id":"11111111-1111-4111-8111-111111111111","code":"040147","name":"Stanbic Bank Uganda"},
              "recipient_amount":"5000.00",
              "processing_fee":"5000.00",
              "provider_fee_cap":"5000.00",
              "maximum_provider_total":"10000.00",
              "customer_debit":"10000.00",
              "kit_debit":"0.00",
              "schedule_version":"kit-pos-v8-2026-08-18",
              "schedule_verified":true,
              "currency":{"code":"UGX","scale":"2"},
              "expires_at":"2099-08-18T23:59:59Z",
              "step_up":{
                "purpose":"bank_transfer",
                "intent":{
                  "action":"transfer",
                  "operation_type":"bank_transfer",
                  "quote_id":"66666666-6666-4666-8666-666666666666",
                  "wallet_id":"33333333-3333-4333-8333-333333333333",
                  "beneficiary_id":"44444444-4444-4444-8444-444444444444",
                  "bank_id":"11111111-1111-4111-8111-111111111111",
                  "bank_code":"040147",
                  "fee_mode":"sender_absorbs",
                  "recipient_amount":"5000.00",
                  "processing_fee":"5000.00",
                  "provider_fee_cap":"5000.00",
                  "maximum_provider_total":"10000.00",
                  "customer_debit":"10000.00",
                  "kit_debit":"0.00",
                  "schedule_version":"kit-pos-v8-2026-08-18",
                  "currency":"UGX"
                }
              }
            }
            """
    }
}
