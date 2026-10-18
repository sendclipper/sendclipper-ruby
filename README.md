# SendClipper Ruby SDK

The official Ruby library for the [SendClipper](https://sendclipper.com) email API.

```bash
gem install sendclipper
# or, in a Gemfile
bundle add sendclipper
```

Ruby 3.1 or newer. No runtime dependencies.

## Setup

Create an API key in the dashboard under **API keys**.

```ruby
require "sendclipper"

client = SendClipper::Client.new("sc_live_xxxxxxxxxxxxxxxx")
# or: SendClipper::Client.new  reads SENDCLIPPER_API_KEY
```

## Send an email

```ruby
data, error = client.emails.send(
  from: "hello@send.acme.io",
  to: "ada@lumen.io",
  subject: "Your receipt",
  html: "<p>Thanks for your order.</p>",
  text: "Thanks for your order."
)

if error
  puts "#{error.name}: #{error.message}" # e.g. domain_not_verified
else
  puts "Email #{data["id"]} accepted"
end
```

Fields are keyword arguments (or a Hash). Top-level names may be snake_case (`template_id:`, `send_class:`), which the SDK turns into the API's camelCase, or the API's own names exactly as the [API reference](https://sendclipper.com/docs) writes them. Values, such as the `variables` map, are sent exactly as given. Responses are Hashes with the API's string keys (`data["id"]`).

`from` must be a bare address on a domain you verified in SendClipper. Each message has one recipient in `to`; for several, use `batch.send`.

## Reply-To and attachments

```ruby
data, error = client.emails.send(
  from: "bookings@acme.io",
  to: "ada@lumen.io",
  subject: "Your booking",
  html: "<p>Your confirmation is attached.</p>",
  reply_to: "support@acme.io",
  attachments: [
    { filename: "booking-42.pdf", content: File.binread("booking-42.pdf") }
  ]
)
```

`reply_to:` is one address or a list of up to 10. `content:` is the file's raw bytes (read it with `File.binread`) and the SDK base64-encodes it; if you already hold base64, pass `content_base64:` instead and it is sent as it is. `content_type:` is guessed from the filename when you leave it out. Limits: 10 MiB per file, 25 MiB of files per message, and your sending provider's own. Attachments are not accepted on a batch item (it fails with `attachments_not_batchable`); send those emails on their own. `sandboxes.send` takes the same fields.

## Send with a template

Design and publish a template in the dashboard, then send it by id or by its send name:

```ruby
client.emails.send(
  from: "hello@send.acme.io",
  to: "ada@lumen.io",
  template_id: "tpl_9f2b7c10ad42", # or template: "welcome"
  variables: { first_name: "Ada" }
)
```

A tag with no value and no `{{tag|fallback}}` is refused by name (`template_variables_missing`), never sent blank.

## Send a batch

Up to 500 messages in one request. Each item is accepted or refused on its own:

```ruby
data, = client.batch.send([
  { from: "hello@send.acme.io", to: "ada@lumen.io", subject: "Hi Ada", html: "<p>Hi</p>" },
  { from: "hello@send.acme.io", to: "alan@lumen.io", template_id: "tpl_9f2b7c10ad42", variables: { first_name: "Alan" } }
])

data["data"].each do |item|
  puts "#{item["index"]} #{item["error"]["code"]}" if item["status"] == "failed"
end
```

## Errors

API methods never raise for an API refusal or a network failure. They return a `SendClipper::Result` with `data`, `error` and `headers`, and exactly one of `data` and `error` is set. A Result destructures to `data, error` and pattern-matches:

```ruby
result = client.domains.list
result.data     # the parsed response, or nil
result.error    # a SendClipper::ErrorResponse, or nil
result.headers  # response headers (lower-case names), or nil when no answer arrived
result.ok?      # error.nil?

domains = client.domains.list.unwrap # data, or raises SendClipper::ApiError

case client.emails.send(**params)
in { error: nil, data: }    then puts data["id"]
in { error: { name: "rate_limited" } } then retry_later
in { error: }               then warn error.message
end
```

`ErrorResponse` has `name` (SendClipper's code: `validation_failed`, `rate_limited`, `network_error`, ...), `message` (a sentence for a person), `status_code` (`nil` when no answer arrived) and `detail` (code-specific facts).

The iterators (`emails.each` and friends) raise a `SendClipper::ApiError` instead, since a loop has no `error` to hand back. `e.code` is the API's code and `e.status` the HTTP status.

## Retries and idempotency

Network errors, `429` and `5xx` answers are retried twice with backoff, honouring `Retry-After`. Every JSON write carries an `Idempotency-Key`, and the API answers a repeated key with the first result for 24 hours. A retried send therefore never goes out twice.

To make your own retries safe as well (a job that runs again after a crash), pass a key that names the logical operation:

```ruby
client.emails.send(**params, idempotency_key: "order-#{order.id}-receipt")
```

## Request options

Every method takes request options as keyword arguments alongside its fields:

```ruby
client.emails.list(status: "bounced", timeout: 5, headers: { "X-Trace-Id" => trace_id })
```

| Option | Meaning |
|---|---|
| `idempotency_key:` | Your own key for a write |
| `timeout:` | Per-attempt timeout in seconds (default 30) |
| `max_retries:` | Retries for this call (default 2) |
| `headers:` | Extra request headers |

Client options: `SendClipper::Client.new(key, base_url:, timeout:, max_retries:, default_headers:, transport:)`. `base_url` also reads `SENDCLIPPER_BASE_URL`. `transport:` replaces the Net::HTTP sender: anything that responds to `call(SendClipper::TransportRequest)` and returns a `SendClipper::TransportResponse`.

## Iterate

Lists that span pages have an `each` method; without a block it returns a lazy Enumerator:

```ruby
client.emails.each(status: "bounced") { |email| puts email["to"] }
first_ten = client.suppressions.each.first(10)
```

## Verify webhooks

SendClipper signs each delivery. Verify it against the **raw** body, before parsing:

```ruby
class SendClipperWebhooksController < ActionController::API
  def create
    event = SendClipper.verify_webhook(
      request.raw_post, # the raw body, not params
      request.headers,
      ENV.fetch("SENDCLIPPER_WEBHOOK_SECRET")
    )
    # event["id"] is stable across retries: deduplicate on it
    Rails.logger.info("#{event["event"]} #{event["data"]["to"]}")
    head :ok
  rescue SendClipper::WebhookVerificationError => e
    render plain: e.reason, status: :bad_request
  end
end
```

In Rack or Sinatra pass `request.body.read` and `request.env`. During a secret rotation a delivery carries two signatures and either one is accepted. A delivery signed more than five minutes away from now is refused. `client.webhooks.verify(...)` is the same function.

To test your handler locally, `SendClipper.webhook_signature_header(secret, raw_body)` builds a valid header.

## Sandboxes

A sandbox traps mail while you develop: nothing is delivered.

```ruby
box = client.sandboxes.create(name: "my-app-dev").unwrap
creds = client.sandboxes.credentials(box["id"]).unwrap # SMTP host, port, username, password

# Or send through the sandbox's JSON door with its own token, using the same fields as emails.send:
token = client.sandboxes.reset_credentials(box["id"]).unwrap
client.sandboxes.send(token["apiToken"], from: "app@example.com", to: "test@example.com", subject: "Hi", html: "<p>Hi</p>")

# In a test: wait for the message to arrive
msg, error = client.sandboxes.messages.wait_for(box["id"]) { |m| m["subject"] == "Hi" }
```

## Everything else

| Resource | Methods |
|---|---|
| `emails` | `send`, `get`, `list`, `each`, `stats` |
| `batch` | `send` |
| `domains` | `list`, `create`, `records`, `verify`, `enable_receiving`, `disable_receiving`, `set_region`, `deletion_preview`, `remove` |
| `templates` | `list`, `get`, `html`, `create`, `update`, `remove`, `duplicate`, `publish`, `unpublish`, `preview`, `set_tags`, `projects` |
| `templates.tags` | `list`, `create`, `update`, `remove` |
| `templates.assets` | `list`, `upload` |
| `sandboxes` | `list`, `get`, `create`, `update`, `remove`, `credentials`, `reset_credentials`, `send` |
| `sandboxes.messages` | `list`, `get`, `raw`, `remove`, `clear`, `mark_all_read`, `wait_for` |
| `webhooks` | `list`, `create`, `update`, `remove`, `rotate_secret`, `deliveries`, `verify` |
| `webhooks.dispatches` | `list`, `each`, `get`, `replay`, `replay_all` |
| `contacts` | `list`, `each`, `create`, `import`, `import_preview`, `export` |
| `audiences` | `list` |
| `suppressions` | `list`, `each`, `create`, `remove`, `export` |
| `mailboxes` | `list`, `get`, `create`, `update`, `archive` |
| `mailboxes.messages` | `list`, `each`, `get`, `attachment` |
| `automations` | `enroll` |
| `workspace` | `get` |
| `api_keys` | `list` |

`contacts.import` takes the file's contents (`File.read("contacts.csv")`) and `templates.assets.upload` the image's bytes (`File.binread("logo.png")`). Management routes need a key with **Full access**. A sending-only key can call `emails.send` and `batch.send`.

Full API reference: <https://sendclipper.com/docs>.

## License

MIT
