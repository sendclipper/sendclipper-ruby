# Changelog

## 0.2.0 — 2026-10-18

- `emails.send`, `sandboxes.send` and each `batch.send` item take `reply_to:` (the API's `replyTo`): one address or a list of up to 10, sent as the `Reply-To` header.
- `emails.send` and `sandboxes.send` take `attachments:`, a list of `{ filename:, content:, content_type: }`. `content:` is the file's raw bytes (`File.binread("invoice.pdf")`) and the SDK base64-encodes it; pass `content_base64:` instead when you already hold base64, and it is sent as it is. Giving both, or a `content:` that is not a String, raises `ArgumentError` before any request. Limits: 10 MiB per file, 25 MiB per message, 20 files. A batch item with attachments is refused by the API (`attachments_not_batchable`).
- Needs the SendClipper API from 2026-10-18 on; an older API ignores both fields.

## 0.1.0 — 2026-10-16

First release.

- `emails.send`, `batch.send`, `emails.get`, `emails.list`, `emails.each`, `emails.stats`.
- Templates (with tags and image assets), domains, sandboxes (including the JSON door and `wait_for`), webhooks and their dispatches, contacts, audiences, suppressions, mailboxes, automations, workspace and API keys.
- Every method returns a `SendClipper::Result` with `data`, `error` and `headers`; it destructures to `data, error` and pattern-matches.
- Fields can be keyword arguments in snake_case (`template_id:`), turned into the API's camelCase.
- Automatic `Idempotency-Key` on every JSON write; retries on network errors, 429 and 5xx.
- `SendClipper.verify_webhook` for `X-SendClipper-Signature-V2`, rotation-aware.
- Ruby 3.1 or newer; no runtime dependencies.
