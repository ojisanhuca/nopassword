require "jwt"

module NoPassword
  # Implements OAuth flow as described at https://developer.apple.com/documentation/sign_in_with_apple/request_an_authorization_to_the_sign_in_with_apple_server
  # Additional API documentation at:
  #  - https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api
  class OAuth::AppleAuthorizationsController < ApplicationController
    CLIENT_ID = ENV["APPLE_CLIENT_ID"]
    TEAM_ID = ENV["APPLE_TEAM_ID"]
    KEY_ID = ENV["APPLE_KEY_ID"]
    PRIVATE_KEY = ENV["APPLE_PRIVATE_KEY"]  # Typically, the contents of the .p8 file

    SCOPE = "name email"

    AUTHORIZATION_URL = URI("https://appleid.apple.com/auth/authorize")
    TOKEN_URL = URI("https://appleid.apple.com/auth/token")
    KEYS_URL = URI("https://appleid.apple.com/auth/keys")

    # Length of `state` parameter token passed into OAuth flow.
    OAUTH_STATE_TOKEN_LENGTH = 32

    # Since Apple POST's this payload back to the server, the built-in
    # `verify_authenticity_token` callback will fail because the origin
    # is appleid.apple.com (Rails wants same origin). This skips that
    # check and instead uses `validate_state_token` to verify CSRF.
    skip_forgery_protection only: :callback
    before_action :validate_state_token, only: :show

    include Routable

    routes.draw do
      resource :apple_authorization, only: [:create, :show] do
        collection do
          post :callback
        end
      end
    end

    def callback
      # There's no session when the POST happens to this callback (thanks Apple and
      # strict cookies!), so we need to redirect to "show" to get the session back,
      # verify the nonce, and setup the user for success.
      id_token = request_access_token.parse.fetch("id_token")
      redirect_to url_for(action: :show, id_token: id_token, **params.permit(:state))
    end

    def show
      user_info = decode_id_token params.fetch(:id_token)

      if user_info.any?
        Rails.logger.info "Authorization #{self.class} succeeded"
        authorization_succeeded user_info
      else
        Rails.logger.info "Authorization #{self.class} failed"
        authorization_failed
      end
    end

    def create
      redirect_to authorization_url.to_s, allow_other_host: true
    end

    protected
      def client_id
        self.class::CLIENT_ID
      end

      def team_id
        self.class::TEAM_ID
      end

      def key_id
        self.class::KEY_ID
      end

      def scope
        self.class::SCOPE
      end

      def private_key
        OpenSSL::PKey::EC.new self.class::PRIVATE_KEY
      end

      def authorization_succeeded(user_info)
        user = User.find_or_create_by(email: user_info.fetch("email"))
        user ||= user_info.fetch("name")

        self.current_user = user
        redirect_to_return_url
      end

      def authorization_failed
        raise "Implement authorization_failed to handle failed authorizations", NotImplementedError
      end

      def validate_state_token
        unless valid_state_token? params.fetch(:state)
          raise ActionController::InvalidAuthenticityToken, "The OAuth state token is inauthentic."
        end
      end

      def generate_state_token
        session[:oauth_state_token] = SecureRandom.base58(OAUTH_STATE_TOKEN_LENGTH)
      end

      def valid_state_token?(token)
        ActiveSupport::SecurityUtils.fixed_length_secure_compare session.fetch(:oauth_state_token), token
      end

      # Documentation at https://developer.apple.com/documentation/accountorganizationaldatasharing/request-an-authorization
      def authorization_url
        AUTHORIZATION_URL.build.query(
          client_id: client_id,
          redirect_uri: callback_url,
          response_type: "code",
          response_mode: "form_post",
          scope: scope,
          state: generate_state_token
        )
      end

      # Documentation at https://developer.apple.com/documentation/accountorganizationaldatasharing/fetch-apple's-public-key-for-verifying-token-signature
      def request_jwks
        HTTP.get(KEYS_URL)
      end

      # Documentation at https://developer.apple.com/documentation/accountorganizationaldatasharing/generate-and-validate-tokens
      def request_access_token
        client_secret = generate_client_secret
        HTTP.post(TOKEN_URL, form: {
          client_id: client_id,
          client_secret: client_secret,
          code: params.fetch(:code),
          grant_type: "authorization_code",
          redirect_uri: callback_url
        })
      end

      def decode_id_token(id_token)
        jwt_options = {
          verify_iss: true,
          iss: "https://appleid.apple.com",
          verify_iat: true,
          verify_aud: true,
          aud: client_id,
          algorithms: ["RS256"],
          jwks: request_jwks.parse
        }
        payload, _header = JWT.decode(id_token, nil, true, jwt_options)
        # verify_nonce!(payload)
        payload
      end

      # Documentation at https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret
      def generate_client_secret
        payload = {
          iss: team_id,
          aud: "https://appleid.apple.com",
          sub: client_id,
          iat: Time.now.to_i,
          exp: Time.now.to_i + 60
        }
        headers = { kid: key_id }

        JWT.encode(payload, private_key, "ES256", headers)
      end

      # The URL the OAuth provider will redirect the user back to after authenticating.
      def callback_url
        url_for(action: :callback, only_path: false)
      end
  end
end
