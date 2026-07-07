# frozen_string_literal: true

require "rack"
require "json"
require_relative "auth"
require "bard/backup"

module Bard
  module Api
    class App
      class << self
        attr_writer :backup_runner, :deploy_runner

        # Runs the backup task out-of-band so the request returns immediately.
        # Override to wire backups into a project's own job queue.
        def backup_runner
          @backup_runner ||= ->(task) { Thread.new { task.call } }
        end

        # bin/setup restarts Puma via `procsd restart` → `systemctl --user restart`, which
        # SIGKILLs the app unit's whole cgroup. So the deploy can't run in this worker (or any
        # plain child of it) — it'd be killed mid-deploy. We run it in its own systemd --user
        # scope: a separate cgroup that survives the restart.
        def deploy_runner
          @deploy_runner ||= method(:spawn_detached_deploy)
        end

        def spawn_detached_deploy(command)
          pid = Process.spawn(
            "systemd-run", "--user", "--scope", "--collect", "--quiet", "bash", "-lc", command,
            :in => "/dev/null", %i[out err] => ["log/bard-deploy.log", "a"],
          )
          Process.detach(pid)
        end
      end

      DEPLOY_LOCK = "tmp/bard-deploy.lock"
      DEPLOY_COMMAND = "flock -n #{DEPLOY_LOCK} -c 'git pull --ff-only origin master && bin/setup'"

      def call(env)
        request = Rack::Request.new(env)
        method = request.request_method
        path = request.path_info

        case [method, path]
        when ["GET", "/health"]
          health(request)
        when ["POST", "/backups"]
          create_backup(request)
        when ["GET", "/backups/latest"]
          latest_backup(request)
        when ["GET", "/config"]
          config(request)
        when ["POST", "/deploy"]
          create_deploy(request)
        else
          not_found
        end
      rescue => e
        json_response(500, { error: e.message })
      end

      private

      def health(request)
        json_response(200, { status: "ok" })
      end

      def create_backup(request)
        with_auth(request) do |payload|
          s3 = payload["s3"].transform_keys(&:to_sym)
          project_name = Bard::Config.current.project_name

          self.class.backup_runner.call(-> { run_backup(project_name, s3) })

          json_response(202, { status: "started" })
        end
      end

      def run_backup(project_name, s3)
        Bard::Backup.create!(
          type: :s3,
          path: "bard-backup/#{project_name}",
          **s3,
        )
      rescue => e
        log_backup_error(e)
      end

      def log_backup_error(error)
        message = "[bard-api] backup failed: #{error.class}: #{error.message}"
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error(message)
          Rails.logger.error(error.backtrace.join("\n")) if error.backtrace
        else
          warn message
          warn error.backtrace.join("\n") if error.backtrace
        end
      end

      def latest_backup(request)
        with_auth(request) do
          backup = Bard::Backup.latest
          json_response(200, backup.as_json)
        end
      rescue Bard::Backup::NotFound => e
        json_response(404, { error: e.message })
      end

      def config(request)
        with_auth(request) do
          json_response(200, serialize_config(Bard::Config.current))
        end
      end

      # Unauthenticated on purpose: it can only fast-forward prod to origin/master (master IS prod)
      # and is a no-op when already there.
      #
      # bin/setup restarts Puma, so we can't run the deploy in this worker thread — the restart
      # would kill it mid-flight. We hand off to an out-of-band process (its own systemd scope,
      # see .deploy_runner), serialize concurrent deploys with an flock, and return 202
      # immediately. The caller polls until HEAD == sha.
      def create_deploy(request)
        target = JSON.parse(request.body.read)["sha"]
        sha = current_sha
        return json_response(200, { status: "noop", sha: sha }) if target == sha
        return json_response(409, { status: "deploying", sha: sha }) if deploy_in_progress?

        self.class.deploy_runner.call(DEPLOY_COMMAND)
        json_response(202, { status: "deploying", sha: sha })
      end

      def current_sha
        `git rev-parse HEAD`.chomp
      end

      def deploy_in_progress?
        File.open(DEPLOY_LOCK, File::RDWR | File::CREAT, 0o644) do |lock|
          acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
          lock.flock(File::LOCK_UN) if acquired
          !acquired
        end
      end

      def serialize_config(bard_config)
        backup = bard_config.backup
        production = bard_config.targets[:production]
        {
          project_name: bard_config.project_name,
          backup: {
            enabled: backup.enabled?,
            bard_managed: backup.bard?,
            self_managed: backup.self_managed?,
            encryption_enabled: !!backup.encrypt,
            destinations: backup.destinations.map { |d| { name: d[:name], type: d[:type] } },
          },
          servers: production ? { production: { pings: production.ping } } : {},
        }
      end

      def with_auth(request)
        payload = Auth.verify!(request.env["HTTP_AUTHORIZATION"])
        yield payload
      rescue Auth::AuthenticationError => e
        json_response(401, { error: "Unauthorized: #{e.message}" })
      end

      def json_response(status, body)
        Rack::Response.new(body.to_json, status, { "Content-Type" => "application/json" }).finish
      end

      def not_found
        json_response(404, { error: "Not found" })
      end
    end
  end
end
