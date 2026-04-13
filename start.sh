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
  begin; puts \"SuperAdmins: #{SuperAdmin.count}\"; SuperAdmin.all.each { |sa| puts \"  SA: #{sa.email}\" }; rescue => e; puts \"SuperAdmin error: #{e.message}\"; end
  begin; puts \"Accounts: #{Account.count}\"; Account.all.each { |a| puts \"  Account #{a.id}: #{a.name}\" }; rescue => e; puts \"Account error: #{e.message}\"; end
  begin; puts \"Users: #{User.count}\"; User.all.each { |u| puts \"  User #{u.id}: #{u.email} role:#{u.role} acc:#{u.account_id} token:#{u.access_token}\" }; rescue => e; puts \"User error: #{e.message}\"; end
  begin; puts \"Inboxes: #{Inbox.count}\"; Inbox.all.each { |i| puts \"  Inbox #{i.id}: #{i.name} acc:#{i.account_id} type:#{i.channel_type}\" }; rescue => e; puts \"Inbox error: #{e.message}\"; end
  begin; puts \"Conversations: #{Conversation.count}\"; rescue => e; puts \"Conv error: #{e.message}\"; end
  begin; puts \"Messages: #{Message.count}\"; rescue => e; puts \"Msg error: #{e.message}\"; end
  begin; puts \"AgentBots: #{AgentBot.count}\"; AgentBot.all.each { |b| puts \"  Bot #{b.id}: #{b.name} acc:#{b.account_id} token:#{b.access_token}\" }; rescue => e; puts \"Bot error: #{e.message}\"; end
  begin; puts \"WebWidgets: #{Channel::WebWidget.count}\"; Channel::WebWidget.all.each { |w| puts \"  Widget #{w.id}: token=#{w.website_token} inbox:#{w.inbox_id}\" }; rescue => e; puts \"Widget error: #{e.message}\"; end
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
    # Always sync password from env var (ensures rotated passwords take effect)
    sa.update_columns(encrypted_password: BCrypt::Password.create(sa_password))
    sa.update_columns(confirmed_at: Time.current) unless sa.confirmed?
    puts \"Updated SuperAdmin password: #{sa.email}\"
  else
    sa = SuperAdmin.create!(
      email: sa_email, password: sa_password,
      name: 'Super Admin', confirmed_at: Time.current
    )
    puts \"Created SuperAdmin: #{sa.email}\"
  end

  # ── Account: Dapper Motor ────────────────────────────────────────────────────
  # Find by id:1 first, then by name
  dapper_account = Account.find_by(id: 1) || Account.find_by(name: 'Dapper Motor')

  if dapper_account
    puts \"Found account #{dapper_account.id}: '#{dapper_account.name}'\"

    # Rename back to Dapper Motor if it was renamed during onboarding
    if dapper_account.name != 'Dapper Motor'
      old_name = dapper_account.name
      dapper_account.update!(name: 'Dapper Motor')
      puts \"Renamed account from '#{old_name}' to 'Dapper Motor'\"
    end

    # Ensure joost@dappermotor.com and rik@dappermotor.com are admins
    ['joost@dappermotor.com', 'rik@dappermotor.com'].each do |email|
      user = User.find_by(email: email)
      if user
        am = AccountMember.find_or_initialize_by(account: dapper_account, user: user)
        am.role = :administrator
        am.save!
        puts \"Ensured admin: #{email}\"
      else
        puts \"User not found: #{email} (not yet created)\"
      end
    end
  else
    puts \"WARNING: No account found — Dapper Motor account missing from database!\"
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
