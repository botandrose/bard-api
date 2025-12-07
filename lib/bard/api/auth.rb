# frozen_string_literal: true

require "jwt"

module Bard
  module Api
    class Auth
      # BARD Tracker's public RSA key for JWT verification
      # This public key can be safely included in the open-source gem
      # Only BARD Tracker with the private key can create valid tokens
      BARD_PUBLIC_KEY = OpenSSL::PKey::RSA.new(<<~KEY)
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyWnrycx4wOR8Hm73F60L
        x0iadR9+r40BRvUPGApg21fxMrNa263rH0nM+W8BX44YpusA1yEbxchbh6lvz7J7
        msjwBgqmpUaSZrSDapoGm7D0bTmXPun84BvFbw0GGOP3K0FYfl859ylaqKw1LyxW
        +b6OK7ccOAM6LmAcILTL9ox4e87SLctXc/Nu8I2Fcj4U83q8chgbtu2JsrqfP8sH
        do0B/dOZRP3Ciwu2tPkwggBVKxGs4dIrXQzjCs7EhKYGGwKa4nyI2/IONebq0w9Q
        QRkn7oivSUNXW3Y+iznoapwgo5c5IO82OrfaQ2tGMvhqtzDa3KNY96ebVCX8HHV/
        gQIDAQAB
        -----END PUBLIC KEY-----
      KEY

      class AuthenticationError < StandardError; end

      def initialize(token)
        @token = token
      end

      def verify!
        raise AuthenticationError, "Missing authorization token" if @token.nil? || @token.empty?

        # Remove 'Bearer ' prefix if present
        token = @token.start_with?("Bearer ") ? @token[7..] : @token

        # Decode and verify the JWT
        payload = JWT.decode(
          token,
          BARD_PUBLIC_KEY,
          true,
          algorithm: "RS256"
        ).first

        # Return the payload for use by the caller
        payload
      rescue JWT::ExpiredSignature
        raise AuthenticationError, "Token has expired"
      rescue JWT::DecodeError => e
        raise AuthenticationError, "Invalid token: #{e.message}"
      end

      def self.verify!(token)
        new(token).verify!
      end
    end
  end
end
