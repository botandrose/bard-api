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
    let(:presigned_url) { "https://s3.amazonaws.com/bucket/backup.sql.gz?signature=abc123" }

    def generate_token(urls:)
      JWT.encode(
        {
          urls: urls,
          exp: (Time.now + 300).to_i,  # 5 minutes from now
          iat: Time.now.to_i
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
      # Mock Backhoe.dump and HTTP.put
      allow(Backhoe).to receive(:dump) do |path|
        File.write(path, "fake dump data")
      end

      mock_response = double("HTTP::Response", status: double(success?: true))
      allow(HTTP).to receive(:put).and_return(mock_response)

      token = generate_token(urls: [presigned_url])
      header "Authorization", "Bearer #{token}"
      post "/backups"

      expect(last_response.status).to eq(200)

      json = JSON.parse(last_response.body)
      expect(json["timestamp"]).not_to be_nil
      expect(json["size"]).to be > 0
      expect(json["destinations"]).to be_an(Array)
      expect(json["destinations"].first["status"]).to eq("success")
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
      token = generate_token
      header "Authorization", "Bearer #{token}"
      get "/backups/latest"

      expect(last_response.status).to eq(404)

      json = JSON.parse(last_response.body)
      expect(json["error"]).to eq("No backups found")
    end
  end
end
