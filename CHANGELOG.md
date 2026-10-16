# Changelog

## 0.1.0 — 2026-10-16

First release.

- `emails.send`, `batch.send`, `emails.get`, `emails.list`, `emails.each`, `emails.stats`.
- Templates (with tags and image assets), domains, sandboxes (including the JSON door and `wait_for`), webhooks and their dispatches, contacts, audiences, suppressions, mailboxes, automations, workspace and API keys.
- Every method returns a `SendClipper::Result` with `data`, `error` and `headers`; it destructures to `data, error` and pattern-matches.
- Fields can be keyword arguments in snake_case (`template_id:`), turned into the API's camelCase.
- Automatic `Idempotency-Key` on every JSON write; retries on network errors, 429 and 5xx.
- `SendClipper.verify_webhook` for `X-SendClipper-Signature-V2`, rotation-aware.
- Ruby 3.1 or newer; no runtime dependencies.
