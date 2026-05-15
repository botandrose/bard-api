# frozen_string_literal: true

require "jwt"

RSpec.describe Bard::Api do
  it "has a version number" do
    expect(Bard::Api::VERSION).not_to be nil
  end
end

RSpec.describe Bard::Api::App do
  def app
    Bard::Api::App.new
  end

  describe "GET /health" do
    it "returns 200 OK with status" do
      get "/health"

      expect(last_response).to be_ok
      expect(last_response.content_type).to include("application/json")

      json = JSON.parse(last_response.body)
      expect(json["status"]).to eq("ok")
    end
  end

  describe "POST /backups" do
    let(:private_key) { OpenSSL::PKey::RSA.new(File.read("#{Dir.pwd}/keys/private_key.pem")) }

    let(:s3_credentials) do
      {
        "access_key_id" => "ASIA_TEST_KEY",
        "secret_access_key" => "test-secret",
        "session_token" => "test-session-token",
        "region" => "us-west-2",
      }
    end

    def generate_token(s3: s3_credentials)
      JWT.encode(
        {
          s3: s3,
          exp: (Time.now + 300).to_i,
          iat: Time.now.to_i,
        },
        private_key,
        "RS256"
      )
    end

    it "returns 401 without authentication" do
      post "/backups"
      expect(last_response.status).to eq(401)

      json = JSON.parse(last_response.body)
      expect(json["error"]).to include("Unauthorized")
    end

    it "returns 401 with invalid token" do
      header "Authorization", "Bearer invalid-token"
      post "/backups"
      expect(last_response.status).to eq(401)
    end

    it "triggers a backup with valid token" do
      bard_config = double(project_name: "test-project")
      allow(Bard::Config).to receive(:current).and_return(bard_config)

      backup_instance = Bard::Backup.new(
        timestamp: Time.now.utc,
        size: 123,
        destinations: [
          { name: "bard", type: "s3", status: "success" }
        ]
      )
      allow(Bard::Backup).to receive(:create!).with(
        type: :s3,
        path: "bard-backup/test-project",
        access_key_id: "ASIA_TEST_KEY",
        secret_access_key: "test-secret",
        session_token: "test-session-token",
        region: "us-west-2",
      ).and_return(backup_instance)

      token = generate_token
      header "Authorization", "Bearer #{token}"
      post "/backups"

      expect(last_response.status).to eq(200)

      json = JSON.parse(last_response.body)
      expect(json["timestamp"]).not_to be_nil
      expect(json["size"]).to be > 0
    end
  end

  describe "GET /backups/latest" do
    let(:private_key) { OpenSSL::PKey::RSA.new(File.read("#{Dir.pwd}/keys/private_key.pem")) }

    def generate_token
      JWT.encode(
        {
          urls: ["https://s3.amazonaws.com/bucket/backup.sql.gz"],
          exp: (Time.now + 300).to_i,  # 5 minutes from now
          iat: Time.now.to_i
        },
        private_key,
        "RS256"
      )
    end

    it "returns 401 without authentication" do
      get "/backups/latest"
      expect(last_response.status).to eq(401)
    end

    it "returns 404 when no backups exist" do
      allow(Bard::Backup).to receive(:latest).and_raise(Bard::Backup::NotFound, "No backups found")
      token = generate_token
      header "Authorization", "Bearer #{token}"
      get "/backups/latest"

      expect(last_response.status).to eq(404)

      json = JSON.parse(last_response.body)
      expect(json["error"]).to eq("No backups found")
    end
  end

  describe "GET /config" do
    let(:private_key) { OpenSSL::PKey::RSA.new(File.read("#{Dir.pwd}/keys/private_key.pem")) }

    def generate_token
      JWT.encode(
        { exp: (Time.now + 300).to_i, iat: Time.now.to_i },
        private_key,
        "RS256"
      )
    end

    def stub_bard_config(backup:, encrypt: false, production_pings: nil, project_name: "test-project")
      production_server = production_pings && double("Server", ping: production_pings)
      servers = production_server ? { production: production_server } : {}
      bard_config = double("Bard::Config",
        project_name: project_name,
        backup: backup,
        encrypt: encrypt,
        servers: servers,
      )
      allow(Bard::Config).to receive(:current).and_return(bard_config)
    end

    it "returns 401 without authentication" do
      get "/config"
      expect(last_response.status).to eq(401)
    end

    it "returns 401 with invalid token" do
      header "Authorization", "Bearer invalid-token"
      get "/config"
      expect(last_response.status).to eq(401)
    end

    it "serializes a bard-managed backup with production ping" do
      backup = Bard::BackupConfig.new { bard }
      stub_bard_config(
        backup: backup,
        encrypt: true,
        production_pings: ["https://pep.example.com/health"],
        project_name: "pep",
      )

      header "Authorization", "Bearer #{generate_token}"
      get "/config"

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("application/json")
      json = JSON.parse(last_response.body)
      expect(json).to eq(
        "project_name" => "pep",
        "backup" => {
          "enabled" => true,
          "bard_managed" => true,
          "self_managed" => false,
          "encryption_enabled" => true,
          "destinations" => [],
        },
        "servers" => {
          "production" => { "pings" => ["https://pep.example.com/health"] },
        },
      )
    end

    it "serializes a self-managed backup with destinations whitelisted to name and type" do
      backup = Bard::BackupConfig.new do
        s3 "primary", path: "secret-bucket/foo", region: "us-west-2", access_key_id: "SECRET"
      end
      stub_bard_config(backup: backup, encrypt: false, production_pings: ["https://example.com"])

      header "Authorization", "Bearer #{generate_token}"
      get "/config"

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json["backup"]["self_managed"]).to eq(true)
      expect(json["backup"]["bard_managed"]).to eq(false)
      expect(json["backup"]["encryption_enabled"]).to eq(false)
      expect(json["backup"]["destinations"]).to eq([
        { "name" => "primary", "type" => "s3" },
      ])
      expect(last_response.body).not_to include("secret-bucket")
      expect(last_response.body).not_to include("SECRET")
    end

    it "serializes a disabled backup" do
      backup = Bard::BackupConfig.new { disabled }
      stub_bard_config(backup: backup, production_pings: ["https://example.com"])

      header "Authorization", "Bearer #{generate_token}"
      get "/config"

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json["backup"]["enabled"]).to eq(false)
      expect(json["backup"]["bard_managed"]).to eq(false)
      expect(json["backup"]["self_managed"]).to eq(false)
    end

    it "omits production server when none configured" do
      backup = Bard::BackupConfig.new { bard }
      stub_bard_config(backup: backup, production_pings: nil)

      header "Authorization", "Bearer #{generate_token}"
      get "/config"

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json["servers"]).to eq({})
    end
  end
end
