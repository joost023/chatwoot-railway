#!/bin/sh
set -e

echo "Waiting for database..."
while ! pg_isready -h ${PGHOST:-${POSTGRES_HOST}} -p ${PGPORT:-5432} -U ${POSTGRES_USERNAME:-postgres}; do
  sleep 0.5
done
echo "Database ready."

echo "Running migrations..."
bundle exec rails db:chatwoot_prepare

echo "Applying installation setup..."
bundle exec rails runner - <<'RUBY'
begin
  # ── Super Admin ─────────────────────────────────────────────────────────────
  sa_email    = ENV.fetch('SUPER_ADMIN_EMAIL', 'joost@ecommerce-manager.nl')
  sa_password = ENV['SUPER_ADMIN_PASSWORD'] or raise 'SUPER_ADMIN_PASSWORD env var is required'

  SuperAdmin.where(email: 'joost@dappermotor.com').destroy_all

  sa = SuperAdmin.find_or_initialize_by(email: sa_email)
  if sa.new_record?
    # Use a temp password that satisfies Devise validation (requires special char)
    # then immediately overwrite via update_columns (bypasses all validations)
    sa.name = 'Super Admin'
    sa.confirmed_at = Time.current
    sa.password = 'Setup@Init1!'
    sa.password_confirmation = 'Setup@Init1!'
    sa.save!
    puts "[SA] Created: #{sa.email}"
  else
    puts "[SA] Found: #{sa.email}"
  end
  # Always set the real password via update_columns (bypasses Devise validation)
  sa.update_columns(
    encrypted_password: BCrypt::Password.create(sa_password),
    confirmed_at: Time.current,
    name: 'Super Admin'
  )

  # ── Account: Dapper Motor ───────────────────────────────────────────────────
  account = Account.find_or_create_by!(id: 1) { |a| a.name = 'Dapper Motor' }
  account.update!(name: 'Dapper Motor') if account.name != 'Dapper Motor'
  puts "[Account] #{account.id}: #{account.name}"

  # ── Helper: get token string ─────────────────────────────────────────────
  get_token = ->(obj) {
    t = obj.access_token rescue nil
    return 'none' unless t
    t.respond_to?(:token) ? t.token : t.to_s
  }

  # ── Users ────────────────────────────────────────────────────────────────
  agent_pass = ENV.fetch('DAPPER_AGENT_PASSWORD', 'ChangeMe!2026x')

  # joost@dappermotor.com
  joost = User.find_by(email: 'joost@dappermotor.com')
  unless joost
    joost = User.new(name: 'Joost Harmsma', email: 'joost@dappermotor.com',
                     password: agent_pass, password_confirmation: agent_pass,
                     confirmed_at: Time.current)
    joost.skip_confirmation!
    joost.save!
    puts "[User] Created: joost@dappermotor.com"
  else
    puts "[User] Exists: joost@dappermotor.com (token=#{get_token.(joost)})"
  end

  # Add to account as administrator
  am_joost = AccountUser.find_or_initialize_by(account_id: account.id, user_id: joost.id)
  am_joost.role = :administrator
  am_joost.availability_status = :online if am_joost.respond_to?(:availability_status=)
  am_joost.save!
  puts "[Member] joost@dappermotor.com → administrator"

  # rik@dappermotor.com
  rik = User.find_by(email: 'rik@dappermotor.com')
  unless rik
    rik = User.new(name: 'Rik', email: 'rik@dappermotor.com',
                   password: agent_pass, password_confirmation: agent_pass,
                   confirmed_at: Time.current)
    rik.skip_confirmation!
    rik.save!
    puts "[User] Created: rik@dappermotor.com"
  else
    puts "[User] Exists: rik@dappermotor.com"
  end

  am_rik = AccountUser.find_or_initialize_by(account_id: account.id, user_id: rik.id)
  am_rik.role = :agent
  am_rik.availability_status = :online if am_rik.respond_to?(:availability_status=)
  am_rik.save!
  puts "[Member] rik@dappermotor.com → agent"

  # ── Bot ─────────────────────────────────────────────────────────────────
  bot = AgentBot.where(account: account).first
  unless bot
    bot = AgentBot.create!(
      name: 'DAPPER Bot',
      account: account,
      outgoing_url: 'https://api.dappermotor.com/webhooks/chatwoot'
    )
    puts "[Bot] Created: DAPPER Bot"
  else
    puts "[Bot] Exists: #{bot.name}"
  end
  bot_token = get_token.(bot)
  puts "[Bot] token=#{bot_token}"

  # ── Website Inbox ────────────────────────────────────────────────────────
  widget = Channel::WebWidget.find_by(account: account)
  if widget
    inbox = widget.inbox
    puts "[Inbox] Exists: #{inbox.name} website_token=#{widget.website_token}"
  else
    widget = Channel::WebWidget.create!(account: account, website_url: 'https://dappermotor.com', widget_color: '#EF4444')
    inbox = Inbox.create!(
      account: account, channel: widget,
      name: 'Dapper Motor Website', channel_type: 'Channel::WebWidget',
      greeting_enabled: true, greeting_message: 'Hoi! Hoe kan ik je helpen? 👋',
      enable_email_collect: false
    )
    puts "[Inbox] Created: #{inbox.name} website_token=#{widget.website_token}"
  end

  # Connect bot to inbox
  unless AgentBotInbox.exists?(inbox: inbox, agent_bot: bot)
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot)
    puts "[Bot] Connected to inbox"
  end

  # Add agents as inbox members
  InboxMember.find_or_create_by!(inbox: inbox, user: joost)
  InboxMember.find_or_create_by!(inbox: inbox, user: rik)
  puts "[Inbox] Members: joost + rik added"

  # ── Labels ───────────────────────────────────────────────────────────────
  [
    { title: 'order-question', color: '#3B82F6' },
    { title: 'return-request', color: '#EF4444' },
    { title: 'product-question', color: '#10B981' },
    { title: 'bot-handled', color: '#6B7280' },
    { title: 'escalated', color: '#F59E0B' }
  ].each do |attrs|
    lbl = Label.find_or_initialize_by(account: account, title: attrs[:title])
    lbl.color = attrs[:color]
    lbl.save!
  end
  puts "[Labels] 5 labels OK"

  # ── Branding ─────────────────────────────────────────────────────────────
  cfg = InstallationConfig.find_or_initialize_by(name: 'CHATWOOT_SHOW_BRANDING')
  cfg.value = false
  cfg.save!
  puts "[Config] Branding disabled"

  # ── Token output ─────────────────────────────────────────────────────────
  joost_token = get_token.(joost)
  puts "=== TOKENS ==="
  puts "CHATWOOT_BOT_TOKEN=#{bot_token}"
  puts "CHATWOOT_USER_TOKEN=#{joost_token}"
  puts "CHATWOOT_ADMIN_TOKEN=#{joost_token}"
  puts "CHATWOOT_WEBSITE_TOKEN=#{widget.website_token}"
  puts "CHATWOOT_ACCOUNT_ID=#{account.id}"
  puts "=== END TOKENS ==="
  puts "Setup complete!"

rescue => e
  puts "SETUP ERROR: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  exit 0  # non-fatal, allow server to start
end
RUBY

echo "Starting services..."
bundle exec sidekiq -C config/sidekiq.yml &
SIDEKIQ_PID=$!

exec bundle exec rails s -b 0.0.0.0 -p ${PORT:-3000}
