import Foundation
#if canImport(StoreKit)
import StoreKit

/// Optional StoreKit 2 helpers, for apps that sell without RevenueCat (with RevenueCat, `linkRevenueCat` is enough).
/// A purchase is sent as `purchase` (the name Apparent joins to sales), a renewal as `subscription_renewed`, a refund
/// as `refund`. Each transaction is sent once: its event id is the transaction id, and the server drops repeats.
@available(iOS 15, macOS 12, *)
public extension Apparent {
    /// Follows `Transaction.updates`: renewals, refunds, Ask to Buy approvals, purchases made on another device.
    /// Call once at launch and keep the task. It never calls `finish()`: your purchase code still does that.
    @discardableResult
    static func observeStoreKitTransactions() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            for await update in Transaction.updates {
                trackTransaction(update)
            }
        }
    }

    /// Records the result of `product.purchase()` (only a finished purchase is sent).
    static func trackPurchase(_ result: Product.PurchaseResult) {
        if case .success(let verification) = result { trackTransaction(verification) }
    }

    /// Records one transaction as `purchase`, `subscription_renewed` or `refund`.
    static func trackTransaction(_ verification: VerificationResult<Transaction>) {
        let verified: Bool
        let transaction: Transaction
        switch verification {
        case .verified(let t): transaction = t; verified = true
        case .unverified(let t, _): transaction = t; verified = false
        }
        let e = StoreKitEvent(transaction, verified: verified)
        shared.track(e.name, properties: e.properties, eventID: e.eventID)
    }
}

@available(iOS 15, macOS 12, *)
struct StoreKitEvent {
    let name: String
    let properties: ApparentProperties
    let eventID: String

    init(_ t: Transaction, verified: Bool) {
        let refunded = t.revocationDate != nil
        let renewal = t.productType == .autoRenewable && t.id != t.originalID
        name = refunded ? "refund" : renewal ? "subscription_renewed" : "purchase"
        var p: ApparentProperties = [
            "store": "app_store",
            "product_id": .string(t.productID),
            "transaction_id": .string(String(t.id)),
            "original_transaction_id": .string(String(t.originalID)),
            "product_type": .string(Self.type(t.productType)),
            "quantity": .int(t.purchasedQuantity),
            "verified": .bool(verified),
        ]
        if let price = t.price { p["price"] = .double(NSDecimalNumber(decimal: price).doubleValue) }
        if #available(iOS 16, macOS 13, *) {
            if let c = t.currency?.identifier { p["currency"] = .string(c) }
            p["environment"] = .string(t.environment.rawValue.lowercased())
        } else if let c = t.currencyCode {
            p["currency"] = .string(c)
        }
        if let offer = t.offerType { p["offer"] = .string(Self.offer(offer)) }
        if refunded { p["refund_reason"] = .string(t.revocationReason == .developerIssue ? "app_issue" : "other") }
        properties = p
        eventID = "storekit:\(name):\(t.id)"
    }

    static func type(_ t: Product.ProductType) -> String {
        switch t {
        case .autoRenewable: return "auto_renewable"
        case .nonRenewable: return "non_renewable"
        case .consumable: return "consumable"
        case .nonConsumable: return "non_consumable"
        default: return t.rawValue
        }
    }

    static func offer(_ o: Transaction.OfferType) -> String {
        switch o {
        case .introductory: return "introductory"
        case .promotional: return "promotional"
        case .code: return "code"
        default: return "other"
        }
    }
}
#endif
