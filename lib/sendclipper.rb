# frozen_string_literal: true

# The official Ruby SDK for the SendClipper email API.
#
#   require "sendclipper"
#
#   client = SendClipper::Client.new("sc_live_...")
#   data, error = client.emails.send(
#     from: "hello@send.acme.io",
#     to: "ada@lumen.io",
#     subject: "Your receipt",
#     html: "<p>Thanks for your order.</p>"
#   )
module SendClipper; end

require_relative "sendclipper/version"
require_relative "sendclipper/errors"
require_relative "sendclipper/result"
require_relative "sendclipper/http_client"
require_relative "sendclipper/webhook"
require_relative "sendclipper/resources/base"
require_relative "sendclipper/resources/emails"
require_relative "sendclipper/resources/domains"
require_relative "sendclipper/resources/templates"
require_relative "sendclipper/resources/sandboxes"
require_relative "sendclipper/resources/webhooks"
require_relative "sendclipper/resources/audience"
require_relative "sendclipper/resources/mailboxes"
require_relative "sendclipper/resources/workspace"
require_relative "sendclipper/client"
