# frozen_string_literal: true

require "rack"
require "json"
require_relative "auth"
require "bard/backup"

module Bard
  module Api
    class App
      class << self
        attr_writer :backup_runner

        # Runs the backup task out-of-band so the request returns immediately.
        # Override to wire backups into a project's own job queue.
        def backup_runner
          @backup_runner ||= ->(task) { Thread.new { task.call } }
        end
      end

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
