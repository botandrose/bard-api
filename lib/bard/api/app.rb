# frozen_string_literal: true

require "rack"
require "json"
require_relative "auth"
require "bard/backup"

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
        json_response(500, { error: e.message })
      end

      private

      def health(request)
        json_response(200, { status: "ok" })
      end

      def create_backup(request)
        with_auth(request) do |payload|
          backup = Bard::Backup.create!(urls: payload["urls"])
          json_response(200, backup.as_json)
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
