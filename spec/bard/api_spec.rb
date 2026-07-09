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

    before do
      # Run the backup synchronously in tests so expectations are deterministic.
      Bard::Api::App.backup_runner = ->(task) { task.call }
    end

    after do
      Bard::Api::App.backup_runner = nil
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

    it "accepts the request and triggers the backup out-of-band" do
      bard_config = double(project_name: "test-project")
      allow(Bard::Config).to receive(:current).and_return(bard_config)

      expect(Bard::Backup).to receive(:create!).with(
        type: :s3,
        path: "bard-backup/test-project",
        access_key_id: "ASIA_TEST_KEY",
        secret_access_key: "test-secret",
        session_token: "test-session-token",
        region: "us-west-2",
      )

      token = generate_token
      header "Authorization", "Bearer #{token}"
      post "/backups"

      expect(last_response.status).to eq(202)

      json = JSON.parse(last_response.body)
      expect(json["status"]).to eq("started")
    end

    it "still returns 202 when the out-of-band backup fails, logging the error" do
      bard_config = double(project_name: "test-project")
      allow(Bard::Config).to receive(:current).and_return(bard_config)
      allow(Bard::Backup).to receive(:create!).and_raise(RuntimeError, "boom")

      token = generate_token
      header "Authorization", "Bearer #{token}"

      expect { post "/backups" }.to output(/backup failed.*boom/m).to_stderr

      expect(last_response.status).to eq(202)
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

    def stub_bard_config(source, project_name: "test-project")
      bard_config = Bard::Config.new(project_name, source: source)
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
      stub_bard_config(<<~RUBY, project_name: "pep")
        target :production do
          ping "https://pep.example.com/health"
        end
        backup do
          bard
          encrypt true
        end
      RUBY

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
      stub_bard_config(<<~RUBY)
        target :production do
          url "https://example.com"
        end
        backup do
          s3 "primary", path: "secret-bucket/foo", region: "us-west-2", access_key_id: "SECRET"
        end
      RUBY

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
      stub_bard_config(<<~RUBY)
        target :production do
          url "https://example.com"
        end
        backup false
      RUBY

      header "Authorization", "Bearer #{generate_token}"
      get "/config"

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json["backup"]["enabled"]).to eq(false)
      expect(json["backup"]["bard_managed"]).to eq(false)
      expect(json["backup"]["self_managed"]).to eq(false)
    end
  end

  describe "POST /deploy" do
    before do
      # Capture the command instead of spawning a real detached deploy.
      Bard::Api::App.deploy_runner = ->(command) { @deploy_command = command }
      allow_any_instance_of(Bard::Api::App).to receive(:current_sha).and_return("cafe1234")
      allow_any_instance_of(Bard::Api::App).to receive(:deploy_in_progress?).and_return(false)
    end

    after do
      Bard::Api::App.deploy_runner = nil
    end

    it "no-ops when prod is already at the requested sha" do
      post "/deploy", { sha: "cafe1234" }.to_json

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("status" => "noop", "sha" => "cafe1234")
      expect(@deploy_command).to be_nil
    end

    it "hands the deploy off out-of-band and returns 202" do
      post "/deploy", { sha: "deadbeef" }.to_json

      expect(last_response.status).to eq(202)
      expect(JSON.parse(last_response.body)).to eq("status" => "deploying", "sha" => "cafe1234")
      expect(@deploy_command).to include("git pull --ff-only origin master")
      expect(@deploy_command).to include("bin/setup")
      # completion is recorded only after bin/setup succeeds
      expect(@deploy_command).to match(/bin\/setup && git rev-parse HEAD > .*bard-deployed\.sha/)
    end

    it "returns 409 without starting a second deploy when one is already running" do
      allow_any_instance_of(Bard::Api::App).to receive(:deploy_in_progress?).and_return(true)

      post "/deploy", { sha: "deadbeef" }.to_json

      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)).to eq("status" => "deploying", "sha" => "cafe1234")
      expect(@deploy_command).to be_nil
    end
  end

  describe ".spawn_detached_deploy" do
    it "runs the deploy in its own systemd --user scope so it survives the app restart" do
      allow(Process).to receive(:spawn).and_return(4321)
      allow(Process).to receive(:detach)

      Bard::Api::App.spawn_detached_deploy("do-deploy")

      expect(Process).to have_received(:spawn).with(
        "systemd-run", "--user", "--scope", "--collect", "--quiet", "bash", "-lc", "do-deploy",
        hash_including(:in => "/dev/null"),
      )
    end

    it "spawns with a clean bundler env so a lockfile change can't crash bundle install" do
      ENV["BUNDLE_GEMFILE"] = "/app/Gemfile"
      seen = :unset
      allow(Process).to receive(:spawn) { seen = ENV["BUNDLE_GEMFILE"]; 4321 }
      allow(Process).to receive(:detach)

      Bard::Api::App.spawn_detached_deploy("do-deploy")

      expect(seen).to be_nil
    ensure
      ENV.delete("BUNDLE_GEMFILE")
    end
  end

  describe "#current_sha" do
    let(:app) { Bard::Api::App.new }

    it "reads the deployed-sha marker when present" do
      allow(File).to receive(:exist?).with(Bard::Api::App::DEPLOYED_SHA).and_return(true)
      allow(File).to receive(:read).with(Bard::Api::App::DEPLOYED_SHA).and_return("abc123\n")
      expect(app.send(:current_sha)).to eq("abc123")
    end

    it "is empty when no deploy has completed, so a bare pull never reads as deployed" do
      allow(File).to receive(:exist?).with(Bard::Api::App::DEPLOYED_SHA).and_return(false)
      expect(app.send(:current_sha)).to eq("")
    end
  end
end
