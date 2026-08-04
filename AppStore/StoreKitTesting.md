# StoreKit release checklist

## Product

- Type: non-consumable
- Product ID: `app.localvoice.LocalVoice.lifetime`
- Reference name: `LocalVoice Lifetime`
- Base price: US $4.99
- App price: Free
- Trial: seven days, managed locally by the app
- Renewal: none

The trial never creates a StoreKit subscription and never charges automatically.
Payment starts only after the customer presses the lifetime purchase button and
confirms the App Store purchase sheet.

## Local testing in Xcode

1. Select the `LocalVoice App Store` scheme.
2. Run the app. The scheme uses `LocalVoice/LocalVoice.storekit`.
3. Confirm that Settings shows seven trial days and the localized App Store price.
4. Open the paywall and test purchase cancellation. Access must remain unchanged.
5. Complete the lifetime purchase. The paywall must close and lifetime access must
   remain active after relaunch.
6. In Xcode, use **Debug > StoreKit > Manage Transactions** to delete the local
   transaction, then use **Restore Purchase** in LocalVoice.
7. Test Ukrainian, Russian, and English app languages.

## Sandbox / TestFlight testing

1. Sign out of any production Media & Purchases account used for testing.
2. Create or use an App Store Connect Sandbox tester.
3. Install the TestFlight build that contains the lifetime product ID.
4. Cancel the purchase sheet once and verify no entitlement is granted.
5. Complete the purchase and relaunch LocalVoice.
6. Delete and reinstall the app, then use **Restore Purchase**.
7. Confirm that the product is still a one-time purchase and that no subscription
   appears in the tester's subscriptions.

## App Review

Attach a screenshot of the in-app paywall to the lifetime purchase in App Store
Connect. The screenshot should show:

- the lifetime unlock button and localized price;
- the Restore Purchase action;
- the statement that this is one payment with no subscription;
- the statement that the seven-day trial does not renew or charge automatically.

Submit the first in-app purchase together with the first app version that uses it.
