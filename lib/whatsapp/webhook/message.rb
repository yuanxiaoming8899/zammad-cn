# Copyright (C) 2012-2024 Zammad Foundation, https://zammad-foundation.org/

class Whatsapp::Webhook::Message
  include Mixin::RequiredSubPaths

  attr_reader :data, :channel, :user, :ticket, :article

  def initialize(data:, channel:)
    @data = data
    @channel = channel
  end

  def process
    @user = create_or_update_user

    UserInfo.current_user_id = user.id
    @ticket = create_or_update_ticket
    @article = create_or_update_article
  end

  private

  def attachment?
    false
  end

  def attachment
    raise NotImplementedError
  end

  def body
    raise NotImplementedError
  end

  def content_type
    raise NotImplementedError
  end

  def create_or_update_user
    user = User.find_by(mobile: user_info[:mobile]) || User.find_by(mobile: user_info[:mobile].delete('+'))
    return user if user.present?

    create_user
  end

  def create_or_update_ticket
    ticket = find_ticket
    return update_ticket(ticket:) if ticket.present?

    create_ticket
  end

  def create_ticket
    title = Translation.translate(Setting.get('locale_default') || 'en-us', __('New WhatsApp message from %s'), "#{profile_name} (#{@user.mobile})")

    Ticket.create!(
      group_id:    @channel.group_id,
      title:,
      state_id:    Ticket::State.find_by(default_create: true).id,
      priority_id: Ticket::Priority.find_by(default_create: true).id,
      customer_id: @user.id,
      preferences: {
        channel_id: @channel.id,
        whatsapp:   ticket_preferences,
      },
    )
  end

  def update_ticket(ticket:)
    new_state_id = ticket.state_id == default_create_ticket_state.id ? ticket.state_id : default_follow_up_ticket_state.id

    preferences = ticket.preferences
    preferences[:whatsapp] ||= {}
    preferences[:whatsapp][:timestamp] = @data[:entry].first[:changes].first[:value][:messages].first[:timestamp]

    ticket.update!(
      preferences:,
      state_id:    new_state_id,
    )

    ticket
  end

  def find_ticket
    state_ids        = Ticket::State.where(name: %w[closed merged removed]).pluck(:id)
    possible_tickets = Ticket.where(customer_id: @user.id).where.not(state_id: state_ids).reorder(:updated_at)

    possible_tickets.find_each.find { |possible_ticket| possible_ticket.preferences[:channel_id] == @channel.id }
  end

  def default_create_ticket_state
    Ticket::State.find_by(default_create: true)
  end

  def default_follow_up_ticket_state
    Ticket::State.find_by(default_follow_up: true)
  end

  def create_or_update_article
    # Editing messages results in being an unsupported type in the Cloud API. Nothing to do here!

    create_article
  end

  def create_article
    article = Ticket::Article.create!(
      ticket_id:    @ticket.id,
      type_id:      Ticket::Article::Type.lookup(name: 'whatsapp message').id,
      sender_id:    Ticket::Article::Sender.lookup(name: 'Customer').id,
      from:         "#{profile_name} (#{@user.mobile})",
      to:           "#{@channel.options[:name]} (#{@channel.options[:phone_number]})",
      message_id:   article_preferences[:message_id],
      internal:     false,
      body:         body,
      content_type: content_type,
      preferences:  {
        whatsapp: article_preferences,
      },
    )

    return article if !attachment?

    create_attachment(article: article)

    article
  end

  def create_attachment(article:)
    data, filename, mime_type = attachment

    Store.create!(
      object:      'Ticket::Article',
      o_id:        article.id,
      data:        data,
      filename:    filename,
      preferences: {
        'Mime-Type' => mime_type,
      },
    )
  rescue Whatsapp::Client::CloudAPIError
    preferences = article.preferences
    preferences[:whatsapp] ||= {}
    preferences[:whatsapp][:media_error] = true
    article.update!(preferences:)
  rescue Whatsapp::Incoming::Media::InvalidMediaTypeError => e
    article.update!(
      body:     e.message,
      internal: true,
    )
  end

  def create_user
    user_data = user_info

    user_data[:active]   = true
    user_data[:role_ids] = Role.signup_role_ids

    User.create(user_data)
  end

  def user_info
    firstname, lastname = User.name_guess(profile_name)

    # Fallback to profile name if no firstname or lastname is found
    if firstname.blank? || lastname.blank?
      firstname, lastname = profile_name.split(%r{\s|\.|,|,\s}, 2)
    end

    {
      firstname: firstname&.strip,
      lastname:  lastname&.strip,
      mobile:    "+#{phone}",
      login:     phone,
    }
  end

  def profile_name
    data[:entry].first[:changes].first[:value][:contacts].first[:profile][:name]
  end

  def phone
    data[:entry].first[:changes].first[:value][:messages].first[:from]
  end

  def ticket_preferences
    {
      from:      {
        phone_number: phone,
        display_name: profile_name,
      },
      timestamp: @data[:entry].first[:changes].first[:value][:messages].first[:timestamp],
    }
  end

  def article_preferences
    {
      entry_id:   @data[:entry].first[:id],
      message_id: @data[:entry].first[:changes].first[:value][:messages].first[:id],
      type:       @data[:entry].first[:changes].first[:value][:messages].first[:type],
    }
  end

  def type
    raise NotImplementedError
  end

  def message
    @message ||= @data[:entry]
      .first[:changes]
      .first[:value][:messages]
      .first[type]
  end
end
