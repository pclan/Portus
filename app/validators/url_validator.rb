require "uri"

# Validates URLs
class UrlValidator < ActiveModel::EachValidator
  # Validator for the url.
  def validate_each(record, attribute, value)
    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    record.errors[attribute] << "is not a valid URL"
    false
  end
end
