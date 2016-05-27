# == Schema Information
#
# Table name: webhooks
#
#  id             :integer          not null, primary key
#  namespace_id   :integer
#  url            :string(255)
#  username       :string(255)
#  password       :string(255)
#  request_method :integer
#  content_type   :integer
#  enabled        :boolean          default("0")
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_webhooks_on_namespace_id  (namespace_id)
#

require "base64"
require "typhoeus"
require "securerandom"
require "json"
require "uri"

# A Webhook describes a kind of callback to an endpoint defined by an URL.
# Futher parameters are username and password, which are used for basic
# authentication. The parameters request_method and content_type are limitted
# to GET and POST, and application/json and application/x-www-form-urlencoded
# respectively. Webhooks can be enabled or disabled.
# After a webhook has been triggered with the provided parameters, a
# WebhookDelivery object is created.
class Webhook < ActiveRecord::Base
  include PublicActivity::Common

  enum request_method: ["GET", "POST"]
  enum content_type: ["application/json", "application/x-www-form-urlencoded"]

  belongs_to :namespace

  has_many :deliveries, class_name: "WebhookDelivery"
  has_many :headers, class_name: "WebhookHeader"

  validates :url, presence: true, url: true

  # default to http if no protocol has been specified. If unspecified, the URL
  # validator will fail.
  before_validation do
    unless url.nil? || url.strip.empty?
      self.url = "http://#{url}" unless url.start_with?("http://") ||
          url.start_with?("https://")
    end
  end

  before_destroy do
    headers.destroy_all
    deliveries.destroy_all
  end

  before_destroy :update_activities!

  # Handle a push event from the registry. All enabled webhooks of the provided
  # namespace are triggered in parallel.
  def self.handle_push_event(event)
    registry = Registry.find_from_event(event)
    return if registry.nil?

    namespace, = Namespace.get_from_name(event["target"]["repository"], registry)
    return if namespace.nil?

    hydra = Typhoeus::Hydra.hydra

    Webhook.where(namespace: namespace).find_each do |webhook|
      next unless webhook.enabled

      headers, auth = headers_from_webhook(webhook)

      args = {
        method:  webhook.request_method,
        headers: headers,
        body:    JSON.generate(event),
        timeout: 60
      }
      args[:userpwd] = auth unless auth.empty?

      hydra.queue create_request(webhook, args, headers, event)
    end

    hydra.run
  end

  # host returns the host part of the URL. This is useful when wanting a pretty
  # representation of a webhook.
  def host
    _, _, host, = URI.split url
    host
  end

  private

  # create_request creates and returns a Request object with the provided arguments.
  def self.create_request(webhook, args, headers, event)
    request = Typhoeus::Request.new(webhook.url, args)

    request.on_complete do |response|
      # prevent uuid clash
      loop do
        @uuid = SecureRandom.uuid
        break if WebhookDelivery.find_by(webhook_id: webhook.id, uuid: @uuid).nil?
      end

      WebhookDelivery.create(
        webhook_id:      webhook.id,
        uuid:            @uuid,
        status:          response.response_code,
        request_header:  headers.to_s,
        request_body:    JSON.generate(event),
        response_header: response.response_headers,
        response_body:   response.response_body)
    end

    request
  end

  # Provide useful parameters for the "timeline" when a webhook has been
  # removed.
  def update_activities!
    PublicActivity::Activity.where(trackable: self).update_all(
      parameters: {
        namespace_id:   namespace.id,
        namespace_name: namespace.clean_name,
        webhook_url:    url
      }
    )
  end

  # headers_from_webhook gathers all headers belonging to the provided webhook.
  # Also, it creates a basic auth string if username and password are provided.
  # The function returns both headers and auth string.
  def self.headers_from_webhook(webhook)
    headers = { "Content-Type" => webhook.content_type }
    WebhookHeader.where(webhook: webhook).find_each do |header|
      headers[header.name] = header.value
    end
    if webhook.username.empty? || webhook.password.empty?
      auth = ""
    else
      auth = "#{webhook.username}:#{webhook.password}"
    end
    [headers, auth]
  end
end
