# frozen_string_literal: true

require "backhoe"
require "http"
require "time"
require "fileutils"

module Bard
  module Api
    class Backup
      class BackupError < StandardError; end

      # Perform a backup to the specified URLs
      def perform(urls)
        raise BackupError, "No URLs provided" if urls.nil? || urls.empty?

        timestamp = Time.now.utc
        destinations = []
        errors = []

        # Create temp file with timestamp
        filename = "#{timestamp.iso8601}.sql.gz"
        temp_path = "/tmp/#{filename}"

        begin
          # Dump database to temp file using Backhoe
          Backhoe.dump(temp_path)

          # Get file size
          file_size = File.size(temp_path)

          # Upload to all URLs in parallel
          threads = urls.map do |url|
            Thread.new do
              begin
                upload_to_url(url, temp_path)
                {
                  name: "bard",
                  type: "bard",
                  status: "success"
                }
              rescue => e
                errors << e
                {
                  name: "bard",
                  type: "bard",
                  status: "failed",
                  error: e.message
                }
              end
            end
          end

          # Wait for all uploads to complete
          destinations = threads.map(&:value)
        ensure
          # Clean up temp file
          FileUtils.rm_f(temp_path)
        end

        # Store backup metadata
        @last_backup = {
          timestamp: timestamp.iso8601,
          size: file_size,
          destinations: destinations
        }

        # Raise error if any destination failed
        unless errors.empty?
          raise BackupError, "Some destinations failed: #{errors.map(&:message).join(", ")}"
        end

        @last_backup
      end

      # Get the latest backup status
      def latest
        # TODO: Retrieve from database instead of instance variable
        @last_backup
      end

      private

      def upload_to_url(url, file_path)
        File.open(file_path, "rb") do |file|
          response = HTTP.put(url, body: file)

          unless response.status.success?
            raise BackupError, "Upload failed with status #{response.status}: #{response.body}"
          end
        end
      end
    end
  end
end
