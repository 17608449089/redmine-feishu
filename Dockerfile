# Redmine with Feishu task sync (SQLite, same layout as official redmine image)
FROM ruby:3.3-bookworm

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development:test" \
    RAILS_SERVE_STATIC_FILES=1 \
    RAILS_LOG_TO_STDOUT=1 \
    HOME=/home/redmine \
    BINDING=0.0.0.0 \
    PORT=3000

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      sqlite3 \
      gosu \
      libyaml-dev \
      shared-mime-info \
      imagemagick \
      ghostscript \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/redmine

COPY Gemfile ./
COPY docker/Gemfile.local Gemfile.local
COPY docker/database.yml config/database.yml

RUN bundle config set --local without "development test" \
    && bundle install --jobs 4 --retry 3 \
    && rm -rf /usr/local/bundle/cache

COPY . .

COPY docker/database.yml config/database.yml
COPY docker/Gemfile.local Gemfile.local
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p tmp/pids tmp/cache log files public/assets sqlite /home/redmine \
    && groupadd --system --gid 999 redmine \
    && useradd --system --uid 999 --gid redmine --home-dir /home/redmine --shell /usr/sbin/nologin redmine \
    && chown -R redmine:redmine /usr/src/redmine /home/redmine \
    && chmod -R ugo=rwX config db log files sqlite tmp \
    && find config db log files sqlite tmp -type d -exec chmod 1777 '{}' +

EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["rails", "server", "-b", "0.0.0.0"]
