# frozen_string_literal: true

require "rack"
require "json"
require_relative "auth"
require_relative "backup"

module Bard
  module Api
    class App
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
        else
          not_found
        end
      rescue => e
        internal_error(e)
      end

      private

      def health(request)
        json_response(200, { status: "ok" })
      end

      def create_backup(request)
        with_auth(request) do |payload|
          # Extract URLs from the JWT payload
          urls = payload["urls"]
          raise "Missing 'urls' in token payload" if urls.nil? || urls.empty?

          # Perform the backup
          backup = Backup.new
          result = backup.perform(urls)

          json_response(200, result)
        end
      rescue => e
        json_response(500, { error: "Backup failed: #{e.message}" })
      end

      def latest_backup(request)
        with_auth(request) do
          # Get the latest backup status
          backup = Backup.new
          result = backup.latest

          if result
            json_response(200, result)
          else
            json_response(404, { error: "No backups found" })
          end
        end
      rescue => e
        json_response(500, { error: e.message })
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

      def internal_error(e)
        json_response(500, { error: "Internal server error: #{e.message}" })
      end
    end
  end
end
