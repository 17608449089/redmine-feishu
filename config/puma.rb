# frozen_string_literal: true

max_threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
min_threads_count = Integer(ENV.fetch("RAILS_MIN_THREADS", max_threads_count))
threads min_threads_count, max_threads_count

bind "tcp://#{ENV.fetch('BINDING', '127.0.0.1')}:#{ENV.fetch('PORT', 3000)}"
environment ENV.fetch("RAILS_ENV", "development")
pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

plugin :tmp_restart
