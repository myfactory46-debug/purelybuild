# PurelyBuild

## Phase 9: PayPal sandbox checkout

The dashboard links each owned project to `checkout.html`. The page reads active offers from Supabase and enables one-time sandbox checkout only. The Cloudflare Worker routes verify the Supabase session, project ownership, and the PayPal order ID before invoking the existing n8n Checkout Start and Checkout Capture production webhooks. The n8n credential stays in a Cloudflare secret, never in browser files.

Cloudflare Workers Builds must deploy this repository with `npx wrangler deploy`, using `wrangler.jsonc`. The `purelybuild` Worker already owns the domain, so do not create a second Worker or change its domain. Configure this Worker secret before enabling checkout:

- `N8N_CHECKOUT_INTERNAL_KEY`: the existing value of n8n's `X-Checkout-Internal-Key` header credential. Store it as an encrypted secret. The production URL and header name are already configured in `worker/index.js`.

Never commit the header value, a Supabase service key, or a PayPal secret. The Supabase publishable key in browser code is intended to be public. Rotate any previously exposed service key separately.

Before deploying, verify the n8n Checkout Start webhook accepts a JSON body with `project_id`, `offer_id`, `provider`, `environment`, and `checkout_request_id`, and returns `approval_url`, `order_id`, `attempt_id`. Set the PayPal Create Order JSON body to `docs/paypal-create-order-body.txt` so PayPal returns to the website. Verify the Capture webhook accepts `attempt_id` and `order_id`. The Worker currently locks provider to PayPal sandbox and rejects subscription offers. The database remains provider-neutral for future payment methods.

The capture/status routes read `payment_attempts` with the authenticated user's JWT and check the owning `projects.user_id`. The owner-read policy in `docs/payment-attempts-owner-read.sql` was applied in Supabase on 2026-09-27; the file records the required setup and should not be run again on that database. On 2026-09-27, the preview checkout completed two end-to-end $1 PayPal sandbox purchases: the capture endpoint returned 200, the signed Payments webhook execution succeeded, and the return page read `completed` from the authenticated payment attempt. Checkout Start and Checkout Capture are published, and both forward the authenticated Supabase session to their respective n8n RPC calls. The preview remains in PR #1 and has not been released to the custom domain.

A separate sandbox checkout was cancelled at PayPal and returned to the preview with `cancelled=1`; the site displayed a cancellation message without invoking capture. The Worker checks ownership before capture/status and returns `completed` without invoking n8n on an already completed attempt. The return page offers an explicit status recheck after a failed or pending confirmation rather than automatically repeating capture.

Before Phase 9 can be marked complete, verify retry/idempotency and cross-account ownership against the backend, and confirm the subscription lifecycle or explicitly defer subscription payments to a later phase. Rotate any previously exposed service key. Do not replay capture on an order whose state is unknown; check the attempt and PayPal order first.
