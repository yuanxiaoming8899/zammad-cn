# Copyright (C) 2012-2024 Zammad Foundation, https://zammad-foundation.org/

module Whatsapp::Webhook
  class Payload
    include Whatsapp::Webhook::Concerns::HasChannel

    def initialize(json:, uuid:, signature:)
      channel = find_channel!(uuid)
      secret = channel.options[:app_secret]

      digest = OpenSSL::Digest.new('sha256')
      raise ValidationError if OpenSSL::HMAC.hexdigest(digest, secret, json) != signature

      @channel = channel
      @data = JSON.parse(json).deep_symbolize_keys

      raise ProcessableError, __('Mismatching phone number id.') if !phone_number_id?
    end

    def process
      raise ProcessableError, __('API error.') if protocol_error?
      raise ProcessableError, __('Unsupported subscription type.') if !subscription_message?

      if status_message?
        process_status_message
      elsif message?
        process_message
      else
        # NeverShouldHappen(TM)
        raise ProcessableError, __('Unsupported webhook payload.')
      end
    end

    private

    def process_message
      raise ProcessableError if message_error?

      type = @data[:entry].first[:changes].first[:value][:messages].first[:type]
      klass = "Whatsapp::Webhook::Message::#{type.capitalize}"

      raise ProcessableError, __('Unsupported message type.') if Whatsapp::Webhook::Message.descendants.map(&:to_s).exclude?(klass)

      klass.constantize.new(data: @data, channel: @channel).process
    end

    def process_status_message
      # noop
    end

    def phone_number_id?
      @data[:entry].first[:changes].first[:value][:metadata][:phone_number_id] == @channel.options[:phone_number_id]
    end

    def subscription_message?
      @data[:entry].first[:changes].first[:field] == 'messages'
    end

    def protocol_error?
      @data[:entry].first[:changes].first[:value].key?(:error)
    end

    def message_error?
      @data[:entry].first[:changes].first[:value][:messages].first.key?(:errors)
    end

    def message?
      @data[:entry].first[:changes].first[:value].key?(:messages)
    end

    def status_message?
      @data[:entry].first[:changes].first[:value].key?(:statuses)
    end

    class ValidationError < StandardError
      def initialize
        super(__('The WhatsApp webhook payload could not be validated.'))
      end
    end

    class ProcessableError < StandardError
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super(__('The WhatsApp webhook payload could not be processed.'))
      end
    end
  end
end
