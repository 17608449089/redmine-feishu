#!/bin/bash
set -euo pipefail

cd /usr/src/redmine

# Same layout as official redmine:latest. Do not honor REDMINE_DB_SQLITE
# (official image also ignores it). Real data lives at sqlite/redmine.db.
mkdir -p tmp/pids tmp/cache log files public/assets sqlite

if [ "$(id -u)" = '0' ]; then
  # Official image: sqlite dir is world-writable so uid 999 can use the volume.
  chmod -R ugo=rwX config db log files sqlite tmp public 2>/dev/null || true
  find config db log files sqlite tmp -type d -exec chmod 1777 '{}' + 2>/dev/null || true
  chown -R redmine:redmine sqlite files 2>/dev/null || true
  exec gosu redmine "$0" "$@"
fi

echo >&2 "=== /usr/src/redmine/sqlite ==="
ls -lah sqlite || true
if [ -f sqlite/redmine.db ]; then
  echo >&2 "users in sqlite/redmine.db: $(sqlite3 sqlite/redmine.db 'select count(*) from users;' 2>/dev/null || echo 'unreadable')"
else
  echo >&2 "WARNING: sqlite/redmine.db is missing"
fi

# Match official docker-entrypoint.sh sqlite fallback (quoted values).
cat > config/database.yml <<'EOF'
production:
  adapter: sqlite3
  host: "localhost"
  username: "redmine"
  database: "sqlite/redmine.db"
  encoding: "utf8"
EOF

if [ -n "${REDMINE_SECRET_KEY_BASE:-}" ] && [ -z "${SECRET_KEY_BASE:-}" ]; then
  export SECRET_KEY_BASE="$REDMINE_SECRET_KEY_BASE"
fi

if [ -z "${SECRET_KEY_BASE:-}" ] && [ ! -f config/initializers/secret_token.rb ]; then
  bundle exec rake generate_secret_token
fi

if [ -n "${FEISHU_APP_ID:-}${FEISHU_APP_SECRET:-}" ]; then
  ruby -e '
require "yaml"
cfg = {
  "default" => {
    "feishu" => {
      "app_id" => ENV["FEISHU_APP_ID"].to_s,
      "app_secret" => ENV["FEISHU_APP_SECRET"].to_s,
      "api_base" => ENV.fetch("FEISHU_API_BASE", "https://open.feishu.cn")
    }
  },
  "production" => {}
}
File.write("config/configuration.yml", YAML.dump(cfg))
'
fi

bundle exec rake db:migrate
rm -f tmp/pids/server.pid

# Single-container Docker has no Sidekiq worker. Inline runs Feishu sync in-process.
cat > config/additional_environment.rb <<'RUBY'
config.active_job.queue_adapter = :inline
RUBY

exec "$@"
