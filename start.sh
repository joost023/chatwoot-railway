#!/bin/sh
set -e

echo "Waiting for database..."
while ! pg_isready -h ${PGHOST:-${POSTGRES_HOST}} -p ${PGPORT:-5432} -U ${POSTGRES_USERNAME:-postgres}; do
  sleep 0.5
done
echo "Database ready."

echo "Running migrations..."
bundle exec rails db:chatwoot_prepare

echo "Applying installation config..."
bundle exec rails runner "
  # v4.12+ requires at least one SuperAdmin to consider installation complete.
  # Create one from env vars if none exists yet.
  if SuperAdmin.none?
    email    = ENV.fetch('SUPER_ADMIN_EMAIL', 'admin@dappermotor.com')
    password = ENV.fetch('SUPER_ADMIN_PASSWORD', SecureRandom.hex(16))
    sa = SuperAdmin.create!(email: email, password: password, name: 'Admin')
    puts \"Created SuperAdmin: #{sa.email}\"
  else
    puts \"SuperAdmin already exists (#{SuperAdmin.count})\"
  end

  # Disable Chatwoot branding in widget
  config = InstallationConfig.find_or_initialize_by(name: 'CHATWOOT_SHOW_BRANDING')
  config.value = false
  config.save!
  puts \"CHATWOOT_SHOW_BRANDING=#{config.value}\"
" 2>&1 || echo "Warning: could not apply installation config (non-critical)"

echo "Starting services..."
bundle exec sidekiq -C config/sidekiq.yml &
SIDEKIQ_PID=$!

exec bundle exec rails s -b 0.0.0.0 -p ${PORT:-3000}
