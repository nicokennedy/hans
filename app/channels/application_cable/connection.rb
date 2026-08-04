module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    # Reuses the same Devise/Warden session the rest of the app already
    # relies on — no parallel authentication system. `env["warden"]` is
    # populated by the same Devise middleware that protects every other
    # controller, so a signed-out visitor or an expired session is rejected
    # exactly like it would be anywhere else in the app.
    def find_verified_user
      verified_user = env["warden"]&.user
      verified_user || reject_unauthorized_connection
    end
  end
end
