# Selling with FastSpring

Connect your own FastSpring store to the License Manager and every order gets a key from it. FastSpring sends the
key in its receipt; your app activates it with this package. Subscription keys renew and end with their FastSpring
subscription.

## 1. Connect your store

1. In the License Manager, open **Settings → Store connection** and choose **Connect FastSpring**.
2. Copy the **token** and the **webhook secret** into your password manager. Each is shown only once. If you lose one,
   make a new one there; the old one stops working at once.

Keep the token private: anyone with it can ask for keys.

## 2. Map each FastSpring product to a version

1. The version must be enabled (the product's page shows its version as Enabled).
2. Choose **Map product**, enter the FastSpring product path (for example `acme-editor`), and choose the version its
   keys are for. Orders for a product that is not mapped get no key.

Mapping a product again changes the version for new orders; keys already sold stay as they are. When you release a
new major version, add a version for it in the License Manager and map the new FastSpring product to it.

## 3. Add the license generator in FastSpring

Each FastSpring product needs its own script.

1. On the product's row in **Store connection**, choose **Script** and copy it.
2. In FastSpring, open the product, choose **Fulfillment**, and add a license generator of the type **PHP Script**.
3. Paste the script and replace `REPLACE_WITH_YOUR_TOKEN` with your token, keeping the quotes. Change nothing else.
4. **For a subscription product**, set the license generator to run on the **first order only** (non-rebill), not on
   renewals. Otherwise every renewal creates a new key.

The script asks the License Manager for one key per unit sold. If the request fails it returns nothing, so FastSpring
retries rather than sending a bad key.

## 4. Add the webhook (needed for subscriptions)

The webhook keeps subscription keys running until each subscription ends, and records refunds and chargebacks on the
key.

In FastSpring, open **Integrations → Webhooks** and add a webhook:

- **URL:** the **webhook address** from Store connection.
- **HMAC SHA256 secret:** your webhook secret.
- **Expanded** data on.
- Events: `order.completed`, `subscription.activated`, `subscription.charge.completed`, `subscription.charge.failed`,
  `subscription.canceled`, `subscription.uncanceled`, `subscription.deactivated`, `return.created`,
  `chargeback.created`.

Turn on test orders too while you test.

## What happens to a subscription key

| In FastSpring | The key |
|---|---|
| First purchase | A new key, linked to the subscription. It renews on the next charge date. |
| Renewal charge | Its end date moves to the new next charge date. Same key. |
| Payment fails | No change. FastSpring retries, and ends the subscription if it keeps failing. |
| Canceled at the end of the period | Runs to the end of the paid period, then ends. |
| Uncanceled | Renews again. |
| Subscription ends (deactivated) | Ends now. Macs stop renewing; each keeps working until its offline license runs out. |
| Refund or chargeback | Recorded on the key, which keeps working. Revoke it in the License Manager if it should stop. |

A few days' allowance is added after each paid-through date, so a renewal that FastSpring reports late never stops an
app. In the app, `LicenseInfo.term` shows the end date: "Renews …" while the subscription runs, and
`.notLicensed(.termEnded)` once it has ended.

## Test before you sell

Use FastSpring's test mode with a test card:

1. Buy the product. The receipt shows a key, and the License Manager lists it.
2. Activate the key in your app, or with `swift run rtfm-license-sample <app-integration.json> activate`.
3. For a subscription: in FastSpring, open **Sales → Subscriptions →** the test subscription, and under **Charges**
   choose **Simulate Next Billing**. The key's end date moves forward, and no second key is made.
