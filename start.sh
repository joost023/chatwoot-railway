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
bundle exec rails runner "
  # ── Super Admin ───────────────────────────────────────────────────────────────
  # Always: joost@ecommerce-manager.nl is the designated Super Admin
  sa_email    = ENV.fetch('SUPER_ADMIN_EMAIL', 'joost@ecommerce-manager.nl')
  sa_password = ENV['SUPER_ADMIN_PASSWORD'] or raise 'SUPER_ADMIN_PASSWORD env var is required'

  # Remove temporary joost@dappermotor.com super admin
  SuperAdmin.where(email: 'joost@dappermotor.com').destroy_all

  sa = SuperAdmin.find_by(email: sa_email)
  if sa
    sa.update_columns(encrypted_password: BCrypt::Password.create(sa_password))
    sa.update_columns(confirmed_at: Time.current) unless sa.confirmed?
    puts \"[SA] Updated: #{sa.email}\"
  else
    sa = SuperAdmin.create!(
      email: sa_email, password: sa_password,
      name: 'Super Admin', confirmed_at: Time.current
    )
    puts \"[SA] Created: #{sa.email}\"
  end

  # ── Account: Dapper Motor (id:1) ─────────────────────────────────────────────
  account = Account.find_or_create_by!(id: 1) do |a|
    a.name = 'Dapper Motor'
  end
  if account.name != 'Dapper Motor'
    account.update!(name: 'Dapper Motor')
    puts \"[Account] Renamed to 'Dapper Motor'\"
  else
    puts \"[Account] OK: #{account.id} = #{account.name}\"
  end

  # ── Agent Users ───────────────────────────────────────────────────────────────
  agent_pass = ENV.fetch('DAPPER_AGENT_PASSWORD', SecureRandom.hex(12))

  # joost@dappermotor.com → Administrator
  joost = User.find_by(email: 'joost@dappermotor.com')
  unless joost
    joost = User.create!(
      name: 'Joost Harmsma',
      email: 'joost@dappermotor.com',
      password: agent_pass,
      password_confirmation: agent_pass,
      confirmed_at: Time.current
    )
    puts \"[User] Created joost@dappermotor.com (password logged below)\"
    puts \"[CREDS] joost@dappermotor.com password=#{agent_pass}\"
  else
    puts \"[User] Already exists: joost@dappermotor.com token=#{joost.access_token}\"
  end
  am_joost = AccountMember.find_or_initialize_by(account: account, user: joost)
  am_joost.role = :administrator; am_joost.save!

  # rik@dappermotor.com → Agent
  rik = User.find_by(email: 'rik@dappermotor.com')
  unless rik
    rik = User.create!(
      name: 'Rik',
      email: 'rik@dappermotor.com',
      password: agent_pass,
      password_confirmation: agent_pass,
      confirmed_at: Time.current
    )
    puts \"[User] Created rik@dappermotor.com (same password)\"
  else
    puts \"[User] Already exists: rik@dappermotor.com\"
  end
  am_rik = AccountMember.find_or_initialize_by(account: account, user: rik)
  am_rik.role = :agent; am_rik.save!

  # ── Bot Agent ─────────────────────────────────────────────────────────────────
  bot = AgentBot.find_by(name: 'DAPPER Bot') || AgentBot.find_by(account: account)
  unless bot
    bot = AgentBot.create!(
      name: 'DAPPER Bot',
      account: account,
      outgoing_url: 'https://api.dappermotor.com/webhooks/chatwoot'
    )
    puts \"[Bot] Created DAPPER Bot\"
  else
    puts \"[Bot] Already exists: #{bot.name}\"
  end
  puts \"[Bot] token=#{bot.access_token}\"

  # ── Website Inbox ─────────────────────────────────────────────────────────────
  website_channel = Channel::WebWidget.find_by(account: account)
  if website_channel
    inbox = website_channel.inbox
    puts \"[Inbox] Already exists: #{inbox.name} token=#{website_channel.website_token}\"
  else
    website_channel = Channel::WebWidget.create!(
      account: account,
      website_url: 'https://dappermotor.com',
      widget_color: '#EF4444'
    )
    inbox = Inbox.create!(
      account: account,
      channel: website_channel,
      name: 'Dapper Motor Website',
      channel_type: 'Channel::WebWidget',
      greeting_enabled: true,
      greeting_message: 'Hoi! Hoe kan ik je helpen? 👋',
      enable_email_collect: false,
      working_hours_enabled: false
    )
    puts \"[Inbox] Created: #{inbox.name} token=#{website_channel.website_token}\"
  end

  # Connect bot to inbox
  existing_bot_hook = AgentBotInbox.find_by(inbox: inbox)
  unless existing_bot_hook
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot)
    puts \"[Bot] Connected to inbox #{inbox.name}\"
  else
    puts \"[Bot] Already connected to inbox\"
  end

  # Add joost as member of inbox
  InboxMember.find_or_create_by!(inbox: inbox, user: joost)
  InboxMember.find_or_create_by!(inbox: inbox, user: rik)

  # ── Labels ────────────────────────────────────────────────────────────────────
  [
    { title: 'order-question', color: '#3B82F6' },
    { title: 'return-request', color: '#EF4444' },
    { title: 'product-question', color: '#10B981' },
    { title: 'bot-handled', color: '#6B7280' },
    { title: 'escalated', color: '#F59E0B' }
  ].each do |label_attrs|
    lbl = Label.find_or_initialize_by(account: account, title: label_attrs[:title])
    lbl.color = label_attrs[:color]
    lbl.save!
  end
  puts \"[Labels] OK\"

  # ── Disable branding ─────────────────────────────────────────────────────────
  config = InstallationConfig.find_or_initialize_by(name: 'CHATWOOT_SHOW_BRANDING')
  config.value = false
  config.save!
  puts \"[Config] CHATWOOT_SHOW_BRANDING=false\"

  # ── Final state ──────────────────────────────────────────────────────────────
  puts '=== TOKENS (copy to Railway Medusa env vars) ==='
  puts \"CHATWOOT_BOT_TOKEN=#{bot.access_token}\"
  puts \"CHATWOOT_USER_TOKEN=#{joost.access_token}\"
  puts \"CHATWOOT_WEBSITE_TOKEN=#{website_channel.website_token}\"
  puts \"CHATWOOT_ACCOUNT_ID=#{account.id}\"
  puts '=== END TOKENS ==='
" 2>&1 || echo "Warning: setup had errors"

echo "Starting services..."
bundle exec sidekiq -C config/sidekiq.yml &
SIDEKIQ_PID=$!

exec bundle exec rails s -b 0.0.0.0 -p ${PORT:-3000}
