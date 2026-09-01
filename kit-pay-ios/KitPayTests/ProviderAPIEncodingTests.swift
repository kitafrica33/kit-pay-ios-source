import Foundation
import XCTest
@testable import KitPay

final class ProviderAPIEncodingTests: XCTestCase {
    func testQuoteRequestPreservesExactScaledAmount() throws {
        let request = CreateProviderQuoteRequest(account: "0412345678", amount: "2500.00")

        let object = try jsonObject(request)

        XCTAssertEqual(object["account"] as? String, "0412345678")
        XCTAssertEqual(object["amount"] as? String, "2500.00")
        XCTAssertEqual(Set(object.keys), ["account", "amount"])
    }

    func testAirtimeQuoteUsesExactRukaPayUgandaPhone() throws {
        let phone = try XCTUnwrap(UgandaMobileMoneyPhone.apiValue(from: "+256 0750 000 002"))
        let request = CreateProviderQuoteRequest(account: phone, amount: "2500.00")

        let object = try jsonObject(request)

        XCTAssertEqual(object["account"] as? String, "256750000002")
    }

    func testProviderOperationRequestUsesQuoteWalletAndSameClientReferenceShape() throws {
        let reference = "ios-provider-1234"
        let binding = ProviderOperationBinding(
            quoteId: "quote-1",
            walletId: "wallet-1",
            clientReference: reference
        )

        let object = try jsonObject(binding.request)

        XCTAssertEqual(object["quote_id"] as? String, "quote-1")
        XCTAssertEqual(object["wallet_id"] as? String, "wallet-1")
        XCTAssertEqual(object["client_reference"] as? String, reference)
        XCTAssertEqual(Set(object.keys), ["quote_id", "wallet_id", "client_reference"])
        XCTAssertEqual(binding.idempotencyKey, reference)
        XCTAssertEqual(binding.stepUpIntent["client_reference"]!, reference)
    }

    func testProviderQuoteReconcilesPrincipalFeeAndExactTotalBeforeApproval() {
        let quote = providerQuote(amount: "5000.00", fee: "150.00", total: "5150.00")
        let mismatched = providerQuote(amount: "5000.00", fee: "150.00", total: "5000.00")

        XCTAssertFalse(quote.isExpired)
        XCTAssertTrue(ProviderMoney.quoteReconciles(quote))
        XCTAssertFalse(ProviderMoney.quoteReconciles(mismatched))
        XCTAssertEqual(quote.amount, "5000.00")
        XCTAssertEqual(quote.fee, "150.00")
        XCTAssertEqual(quote.total, "5150.00")
    }

    func testProviderStatusPollingAcceptsOnlySameImmutablePaymentAndStopsAtTerminal() {
        let pending = providerOperation(status: "pending", total: "5150.00")
        let succeeded = providerOperation(status: "succeeded", total: "5150.00")
        let changedTotal = providerOperation(status: "succeeded", total: "6000.00")
        let reversed = providerOperation(status: "reversed", total: "5150.00")

        XCTAssertFalse(pending.isTerminal)
        XCTAssertTrue(succeeded.isTerminal)
        XCTAssertTrue(succeeded.isSuccessful)
        XCTAssertTrue(reversed.isTerminal)
        XCTAssertFalse(reversed.isSuccessful)
        XCTAssertTrue(succeeded.hasSamePaymentBinding(as: pending))
        XCTAssertFalse(changedTotal.hasSamePaymentBinding(as: pending))
    }

    func testBillStepUpIntentContainsOnlyOperationBindingFields() throws {
        let request = CreateStepUpRequest(
            purpose: ProviderService.bill.operationType,
            intent: [
                "quote_id": "quote-1",
                "wallet_id": "wallet-1",
                "client_reference": "ios-provider-1234",
            ]
        )

        let object = try jsonObject(request)
        let intent = try XCTUnwrap(object["intent"] as? [String: Any])

        XCTAssertEqual(object["purpose"] as? String, "bill_payment")
        XCTAssertEqual(intent["quote_id"] as? String, "quote-1")
        XCTAssertEqual(intent["wallet_id"] as? String, "wallet-1")
        XCTAssertEqual(intent["client_reference"] as? String, "ios-provider-1234")
        XCTAssertEqual(Set(intent.keys), ["quote_id", "wallet_id", "client_reference"])
        XCTAssertEqual(ProviderService.airtime.operationType, "airtime_purchase")
    }

    func testProviderAmountUsesProductScaleWithoutRounding() {
        XCTAssertEqual(ProviderMoney.apiAmount("1,250.5", scale: 2), "1250.50")
        XCTAssertEqual(ProviderMoney.apiAmount("0007", scale: 0), "7")
        XCTAssertNil(ProviderMoney.apiAmount("1.005", scale: 2))
        XCTAssertNil(ProviderMoney.apiAmount("0", scale: 2))
    }

    func testRukaPayUGXQuotesSendOnlyPositiveWholeShillings() throws {
        let product = providerProduct(providerCode: "rukapay", serviceType: "airtime")

        XCTAssertTrue(product.requiresWholeUGXRukaPayAmount)
        XCTAssertEqual(ProviderMoney.apiAmount("1,250", product: product), "1250")
        XCTAssertEqual(ProviderMoney.apiAmount("٠٠١٬٢٥٠", product: product), "1250")
        XCTAssertEqual(ProviderMoney.normalizedWholeUGXInput("1,250"), "1250")
        XCTAssertNil(ProviderMoney.normalizedWholeUGXInput("1.5"))
        XCTAssertNil(ProviderMoney.apiAmount("1.5", product: product))
        XCTAssertNil(ProviderMoney.apiAmount("1,250.00", product: product))
        XCTAssertNil(ProviderMoney.apiAmount("0", product: product))
        XCTAssertNil(ProviderMoney.apiAmount("-1", product: product))

        let amount = try XCTUnwrap(ProviderMoney.apiAmount("2,500", product: product))
        let object = try jsonObject(CreateProviderQuoteRequest(account: "256750000002", amount: amount))
        XCTAssertEqual(object["amount"] as? String, "2500")
        XCTAssertFalse((object["amount"] as? String)?.contains(".") == true)
    }

    func testRukaPayWholeRequestMatchesScaleFormattedQuoteResponse() {
        XCTAssertTrue(ProviderMoney.amountsMatch("2500", "2500.00"))
        XCTAssertFalse(ProviderMoney.amountsMatch("2500", "2500.01"))
    }

    func testNonRukaPayProviderKeepsCatalogScaleBehavior() {
        let product = providerProduct(providerCode: "sandbox", serviceType: "bill")

        XCTAssertFalse(product.requiresWholeUGXRukaPayAmount)
        XCTAssertEqual(ProviderMoney.apiAmount("1,250.5", product: product), "1250.50")
    }

    func testAirtimeCatalogSelectsAirtelFirstAndUsesNetworkOnlyNames() {
        let mtn = providerProduct(
            providerCode: "rukapay",
            serviceType: "airtime",
            id: "mtn-product",
            code: "MTN_AIRTIME",
            name: "MTN Mobile Money Airtime"
        )
        let airtel = providerProduct(
            providerCode: "rukapay",
            serviceType: "airtime",
            id: "airtel-product",
            code: "AIRTEL_MONEY_AIRTIME",
            name: "Airtel Money Airtime"
        )
        let unrelatedBill = providerProduct(
            providerCode: "rukapay",
            serviceType: "bill",
            id: "airtel-bill",
            code: "AIRTEL_POSTPAID",
            name: "Airtel postpaid bill"
        )

        let ordered = AirtimeProductPresentationPolicy.ordered([mtn, airtel])

        XCTAssertEqual(ordered.map(\.id), ["airtel-product", "mtn-product"])
        XCTAssertEqual(
            AirtimeProductPresentationPolicy.preferredProductID(in: [mtn, airtel]),
            "airtel-product"
        )
        XCTAssertEqual(airtel.customerFacingName, "Airtel airtime")
        XCTAssertEqual(mtn.customerFacingName, "MTN airtime")
        XCTAssertFalse(airtel.customerFacingName.localizedCaseInsensitiveContains("money"))
        XCTAssertEqual(unrelatedBill.customerFacingName, "Airtel postpaid bill")
    }

    func testCustomerFacingPaymentCopyRemovesProviderBrand() {
        XCTAssertEqual(CustomerFacingPaymentCopy.transactionFeeTitle, "Transaction fee")
        XCTAssertFalse(
            CustomerFacingPaymentCopy.transactionFeeTitle.localizedCaseInsensitiveContains("kit")
        )
        XCTAssertFalse(
            CustomerFacingPaymentCopy.transactionFeeTitle.localizedCaseInsensitiveContains("provider")
        )
        XCTAssertEqual(
            CustomerFacingPaymentCopy.neutralizedServiceMessage("RukaPay could not verify this request."),
            "Kit Pay's payment service could not verify this request."
        )
        XCTAssertEqual(
            CustomerFacingPaymentCopy.neutralizedServiceMessage("RUKA-PAY is unavailable; ruka_pay timed out."),
            "Kit Pay's payment service is unavailable; Kit Pay's payment service timed out."
        )
        XCTAssertEqual(
            CustomerFacingPaymentCopy.neutralizedServiceMessage("Ruka is temporarily unavailable."),
            "Kit Pay's payment service is temporarily unavailable."
        )
    }

    func testMobileMoneyAccountVerificationNeverDisplaysRawProviderDiagnostics() {
        let error = APIErrorPayload(
            code: "MOBILE_MONEY_VERIFICATION_PROVIDER_FAILURE",
            message: "MTN gateway settlement ledger commission allocation failed."
        )

        let displayed = MobileMoneyAccountVerificationErrorCopy.message(for: error)

        XCTAssertEqual(displayed, MobileMoneyAccountVerificationErrorCopy.genericFailure)
        for forbidden in ["MTN", "gateway", "settlement", "ledger", "commission"] {
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testCustomerFacingPaymentCopyNeverExposesInternalFeeBreakdown() {
        let protectedCopy =
            "We couldn't complete this request. Review the transaction fee and total before continuing."
        let internalMessages = [
            "Provider fee UGX 3,000 and Kit Pay fee UGX 3,000.",
            "Provider transaction fee UGX 3,000 plus platform processing fee UGX 3,000.",
            "platform_fee=3000; provider_fee_cap=3000",
            "The service charge could not be reconciled.",
            "Maximum provider settlement exceeded the approved amount.",
            "The fee breakdown is unavailable.",
            "RukaPay fee allowance changed.",
            "RukaPay transaction fee changed.",
            "Kit Pay's commission share could not be calculated.",
        ]

        for message in internalMessages {
            let displayed = CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
            XCTAssertEqual(displayed, protectedCopy)
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("provider"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("platform"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("Kit Pay fee"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("Ruka"))
        }

        XCTAssertEqual(
            CustomerFacingPaymentCopy.neutralizedServiceMessage(
                "The transaction fee changed. Review the latest total."
            ),
            "The transaction fee changed. Review the latest total."
        )
    }

    func testCustomerFacingPaymentCopyNeverExposesStandaloneAccountingDiagnostics() {
        let protectedCopy =
            "We couldn't complete this request. Please try again or contact support with the reference."
        let internalMessages = [
            "institutional revenue ledger settlement wallet margin allocation",
            "Commission allocation failed.",
            "Revenue ledger entry is missing.",
            "Settlement account reconciliation failed.",
            "Rounding adjustment could not be posted.",
            "Provider float balance is unavailable.",
            "institutional_commission posting failed.",
            "settlement-wallet ledger mismatch.",
            "provider_float balance unavailable.",
            "Internal accounting posting failed.",
            "Processing cost allocation failed.",
            "journal_entry could not be written.",
        ]

        for message in internalMessages {
            let displayed = CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
            XCTAssertEqual(displayed, protectedCopy)
            for forbidden in [
                "institutional", "commission", "revenue", "ledger", "settlement", "margin",
                "reconciliation", "rounding", "provider float",
            ] {
                XCTAssertFalse(displayed.localizedCaseInsensitiveContains(forbidden))
            }
        }
    }

    func testCustomerFacingPaymentCopyNeverExposesWholeUnitRailConstraints() {
        let protectedCopy = "We couldn't process this amount. Review it and try again."
        for message in [
            "RukaPay supports whole-shilling amounts only.",
            "The amount must be an integer.",
            "No decimals are supported for this amount.",
            "Enter a whole number amount.",
            "Amounts with decimal places are not supported by RUKA_PAY.",
            "Fractional UGX values are unsupported.",
            "UGX cents are not accepted.",
            "Only integer currency values are accepted.",
            "The amount must use whole currency units.",
        ] {
            let displayed = CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
            XCTAssertEqual(displayed, protectedCopy)
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("Ruka"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("whole-shilling"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("integer"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("decimal"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("fractional"))
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("cents"))
        }
    }

    func testCustomerFacingPaymentCopyRemovesProviderLegalNameVariants() {
        for message in [
            "Ruka Payments is unavailable.",
            "RukaPay Uganda Limited timed out.",
            "RUKA-PAY UGANDA LTD. could not complete the request.",
        ] {
            let displayed = CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
            XCTAssertFalse(displayed.localizedCaseInsensitiveContains("ruka"))
            XCTAssertTrue(displayed.localizedCaseInsensitiveContains("payment service"))
        }
    }

    func testCustomerFacingPaymentCopyPreservesActionablePaymentErrors() {
        for message in [
            "The amount is below the minimum of UGX 20,000.",
            "Your wallet balance is insufficient for this payment.",
            "The recipient could not be verified. Check the number and try again.",
            "The transaction fee changed. Review the latest total.",
        ] {
            XCTAssertEqual(
                CustomerFacingPaymentCopy.neutralizedServiceMessage(message),
                message
            )
        }
    }

    func testConfirmedMobileMoneyCollectionFailureCopyIsProviderNeutralAndReconciliationSafe() {
        let expected =
            "The mobile-money network could not complete this collection. No money was added to your wallet. Check your balance and approval prompt before trying again. If your balance changed, do not retry—contact support with the reference."

        XCTAssertEqual(
            CustomerFacingPaymentCopy.confirmedMobileMoneyCollectionFailureMessage(
                for: "BANK_PROVIDER_FAILED"
            ),
            expected
        )
        XCTAssertEqual(
            CustomerFacingPaymentCopy.confirmedMobileMoneyCollectionFailureMessage(
                for: "mobile-money-provider-failed"
            ),
            expected
        )
        XCTAssertNil(
            CustomerFacingPaymentCopy.confirmedMobileMoneyCollectionFailureMessage(
                for: "BANK_PROVIDER_OUTCOME_UNKNOWN"
            )
        )
        XCTAssertFalse(expected.localizedCaseInsensitiveContains("Ruka"))
        XCTAssertFalse(expected.localizedCaseInsensitiveContains("provider"))
    }

    func testProviderAmountHonorsCatalogRange() {
        let product = ProviderProductDTO(
            id: "product-1",
            code: "POWER",
            name: "Power",
            serviceType: "bill",
            provider: ProviderSummaryDTO(
                id: "provider-1",
                code: "RUKA",
                name: "RukaPay",
                countryCode: "UG"
            ),
            category: ProviderCategoryDTO(
                id: "category-1",
                serviceType: "bill",
                code: "electricity",
                name: "Electricity",
                displayOrder: nil
            ),
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            minimumAmount: "1000.00",
            maximumAmount: "10000.00"
        )

        XCTAssertTrue(ProviderMoney.isWithinProductRange("1000.00", product: product))
        XCTAssertTrue(ProviderMoney.isWithinProductRange("10000.00", product: product))
        XCTAssertFalse(ProviderMoney.isWithinProductRange("999.99", product: product))
        XCTAssertFalse(ProviderMoney.isWithinProductRange("10000.01", product: product))
    }

    func testProviderAmountRangeCopyGroupsDigitsAndTrimsInsignificantZeros() {
        let product = providerProduct(
            providerCode: "rukapay",
            serviceType: "bill",
            minimumAmount: "1768.80",
            maximumAmount: "1856.84"
        )

        XCTAssertEqual(
            ProviderAmountRangeCopy.text(for: product),
            "Available from UGX 1,768.8 to 1,856.84"
        )
    }

    func testProviderCapabilitiesFailClosedAndRequireWallets() {
        let available = CapabilitiesDTO(
            apiVersion: "1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["wallets": true, "bills": true, "airtime": false],
            authentication: nil
        )
        let missingWallet = CapabilitiesDTO(
            apiVersion: "1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["bills": true, "airtime": true],
            authentication: nil
        )
        let unknown = CapabilitiesDTO(
            apiVersion: "1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["wallets": true, "bills": nil],
            authentication: nil
        )

        XCTAssertTrue(available.enablesProviderService(.bill))
        XCTAssertFalse(available.enablesProviderService(.airtime))
        XCTAssertFalse(missingWallet.enablesProviderService(.bill))
        XCTAssertFalse(missingWallet.enablesProviderService(.airtime))
        XCTAssertFalse(unknown.enablesProviderService(.bill))
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func providerProduct(
        providerCode: String,
        serviceType: String,
        id: String = "product-1",
        code: String = "PRODUCT",
        name: String = "Provider product",
        minimumAmount: String? = "500.00",
        maximumAmount: String? = "5000000.00"
    ) -> ProviderProductDTO {
        ProviderProductDTO(
            id: id,
            code: code,
            name: name,
            serviceType: serviceType,
            provider: ProviderSummaryDTO(
                id: "provider-1",
                code: providerCode,
                name: providerCode,
                countryCode: "UG"
            ),
            category: ProviderCategoryDTO(
                id: "category-1",
                serviceType: serviceType,
                code: serviceType,
                name: serviceType.capitalized,
                displayOrder: nil
            ),
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            minimumAmount: minimumAmount,
            maximumAmount: maximumAmount
        )
    }

    private func providerQuote(
        amount: String,
        fee: String,
        total: String
    ) -> ProviderQuoteDTO {
        ProviderQuoteDTO(
            id: "11111111-1111-4111-8111-111111111111",
            productId: "product-1",
            providerCode: "rukapay",
            serviceType: "airtime",
            accountDisplay: "+256 7•• ••• 002",
            amount: amount,
            fee: fee,
            total: total,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            expiresAt: "2099-08-18T12:05:00Z"
        )
    }

    private func providerOperation(status: String, total: String) -> ProviderOperationDTO {
        ProviderOperationDTO(
            id: "22222222-2222-4222-8222-222222222222",
            type: "airtime_purchase",
            status: status,
            walletId: "33333333-3333-4333-8333-333333333333",
            providerCode: "rukapay",
            productId: "product-1",
            productName: "MTN Airtime",
            accountDisplay: "+256 7•• ••• 002",
            amount: "5000.00",
            fee: "150.00",
            total: total,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            clientReference: "ios-provider-1234",
            providerStatus: nil,
            providerReference: nil,
            createdAt: "2026-08-18T12:00:00Z"
        )
    }
}
