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
  puts '=== DATABASE STATE ==='
  puts \"SuperAdmins: #{SuperAdmin.count}\"
  SuperAdmin.all.each { |sa| puts \"  SA: #{sa.email}\" }
  puts \"Accounts: #{Account.count}\"
  Account.all.each { |a| puts \"  Account #{a.id}: #{a.name}\" }
  puts \"Users: #{User.count}\"
  User.all.each { |u| puts \"  User #{u.id}: #{u.email} role:#{u.role} account:#{u.account_id} token:#{u.access_token}\" }
  puts \"Inboxes: #{Inbox.count}\"
  Inbox.all.each { |i| puts \"  Inbox #{i.id}: #{i.name} account:#{i.account_id}\" }
  puts \"Conversations: #{Conversation.count}\"
  puts \"AgentBots: #{AgentBot.count}\"
  AgentBot.all.each { |b| puts \"  Bot #{b.id}: #{b.name} token:#{b.access_token}\" }
  puts '=== END STATE ==='

  # ── Super Admin setup ────────────────────────────────────────────────────────
  # joost@ecommerce-manager.nl is the designated Super Admin
  sa_email    = ENV.fetch('SUPER_ADMIN_EMAIL', 'joost@ecommerce-manager.nl')
  sa_password = ENV['SUPER_ADMIN_PASSWORD'] or raise 'SUPER_ADMIN_PASSWORD env var is required'

  # Remove the temporary joost@dappermotor.com super admin if it exists
  # and replace with joost@ecommerce-manager.nl
  old_sa = SuperAdmin.find_by(email: 'joost@dappermotor.com')
  old_sa.destroy! if old_sa && sa_email != 'joost@dappermotor.com'

  sa = SuperAdmin.find_by(email: sa_email)
  if sa
    puts \"SuperAdmin already exists: #{sa.email}\"
  else
    sa = SuperAdmin.create!(email: sa_email, password: sa_password, name: 'Super Admin', confirmed_at: Time.current)
    puts \"Created SuperAdmin: #{sa.email}\"
  end
  # Ensure super admin email is confirmed (skip Devise confirmation email)
  unless sa.confirmed?
    sa.update_columns(confirmed_at: Time.current)
    puts \"Confirmed SuperAdmin: #{sa.email}\"
  end

  # ── Account: Dapper Motor (account_id: 1) ───────────────────────────────────
  dapper_account = Account.find_by(id: 1)
  if dapper_account.nil?
    # Find by name as fallback
    dapper_account = Account.find_by(name: 'Dapper Motor')
  end

  if dapper_account
    puts \"Found Dapper Motor account: #{dapper_account.id}\"

    # Ensure joost@dappermotor.com is an admin agent in this account
    ['joost@dappermotor.com', 'rik@dappermotor.com'].each do |email|
      user = User.find_by(email: email)
      if user
        am = AccountMember.find_by(account: dapper_account, user: user)
        if am
          puts \"User #{email} already in account (role: #{am.role})\"
          # Ensure admin role
          am.update!(role: :administrator) unless am.administrator?
        else
          AccountMember.create!(account: dapper_account, user: user, role: :administrator)
          puts \"Added #{email} to Dapper Motor account as admin\"
        end
      else
        puts \"User #{email} not found in database (may need to be created manually)\"
      end
    end
  else
    puts \"WARNING: Dapper Motor account not found in database!\"
  end

  # ── Disable branding ─────────────────────────────────────────────────────────
  config = InstallationConfig.find_or_initialize_by(name: 'CHATWOOT_SHOW_BRANDING')
  config.value = false
  config.save!
  puts \"CHATWOOT_SHOW_BRANDING=#{config.value}\"
" 2>&1 || echo "Warning: installation setup had errors (non-critical)"

echo "Starting services..."
bundle exec sidekiq -C config/sidekiq.yml &
SIDEKIQ_PID=$!

exec bundle exec rails s -b 0.0.0.0 -p ${PORT:-3000}
