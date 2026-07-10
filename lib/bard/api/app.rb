# frozen_string_literal: true

require "rack"
require "json"
require "bundler"
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

        # with_unbundled_env is essential: this worker runs under the app's bundle
        # (RUBYOPT=-rbundler/setup, BUNDLE_GEMFILE). Inherited into the deploy, that makes every
        # ruby command — bundle install included — crash at startup the moment git pull lands a
        # lockfile with not-yet-installed gems. The deploy must start from a clean env.
        def spawn_detached_deploy(command)
          Bundler.with_unbundled_env do
            pid = Process.spawn(
              "systemd-run", "--user", "--scope", "--collect", "--quiet", "bash", "-lc", command,
              :in => "/dev/null", %i[out err] => ["log/bard-deploy.log", "a"],
            )
            Process.detach(pid)
          end
        end
      end

      DEPLOY_LOCK = "tmp/bard-deploy.lock"
      DEPLOYED_SHA = "tmp/bard-deployed.sha"
      FAILED_SHA = "tmp/bard-deploy-failed.sha"
      DEPLOY_LOG = "log/bard-deploy.log"
      # How long a failed sha short-circuits re-deploy: long enough to end the caller's poll loop
      # without a re-spawn, short enough that a fresh `bard deploy` run can retry the same sha.
      FAILED_COOLDOWN = 60

      # Record the deployed sha only after bin/setup fully succeeds — a bare `git pull` advances
      # HEAD before the bundle/migrate/restart run, so HEAD alone would read as "done" too early.
      # On any failure, stamp the attempted sha so we don't re-spawn (and restart Puma) on every
      # poll; the marker is written inside the flock, so it's on disk before the lock releases.
      DEPLOY_COMMAND =
        "flock -n #{DEPLOY_LOCK} -c '" \
          "rm -f #{FAILED_SHA}; " \
          "git pull --ff-only origin master && bin/setup && git rev-parse HEAD > #{DEPLOYED_SHA} " \
          "|| git rev-parse origin/master > #{FAILED_SHA}'"

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

        # A prior attempt at this exact sha just failed. Report it instead of re-spawning the
        # deploy on every poll (which would restart Puma every few seconds and never converge).
        if target == failed_sha && recently_failed?
          return json_response(500, {
            status: "failed",
            sha: sha,
            error: "deploy failed on the server; see #{DEPLOY_LOG}",
            log: deploy_log_tail,
          })
        end

        self.class.deploy_runner.call(DEPLOY_COMMAND)
        json_response(202, { status: "deploying", sha: sha })
      end

      # The last FULLY deployed sha (bin/setup succeeded), not merely where git HEAD points.
      # Absent marker => nothing has completed yet, so it can never match the requested sha and
      # the caller keeps polling until bin/setup writes it — or times out on a real failure.
      def current_sha
        return "" unless File.exist?(DEPLOYED_SHA)
        File.read(DEPLOYED_SHA).chomp
      end

      # The sha whose deploy most recently failed (bin/setup or the git pull errored out).
      def failed_sha
        return "" unless File.exist?(FAILED_SHA)
        File.read(FAILED_SHA).chomp
      end

      def recently_failed?
        File.exist?(FAILED_SHA) && (Time.now - File.mtime(FAILED_SHA)) < FAILED_COOLDOWN
      end

      def deploy_log_tail(lines = 30)
        return "" unless File.exist?(DEPLOY_LOG)
        File.readlines(DEPLOY_LOG).last(lines).join
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
