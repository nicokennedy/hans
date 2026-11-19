# Cambio obligatorio de la contraseña temporal (Administración → Usuarios). Mientras
# must_change_password esté activo, ApplicationController manda acá al usuario en cualquier
# pantalla. Al guardarla se mantiene la sesión actual (bypass_sign_in): las demás quedan
# invalidadas porque cambió la contraseña.
class PasswordChangesController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :require_password_change!

  layout -> { current_user&.driver? ? "reparto" : "application" }

  MIN_LENGTH = 8

  def edit
  end

  def update
    password = params[:password].to_s
    confirmation = params[:password_confirmation].to_s
    error =
      if password.length < MIN_LENGTH then "La contraseña tiene que tener al menos #{MIN_LENGTH} caracteres."
      elsif password != confirmation then "Las dos contraseñas no coinciden."
      elsif current_user.valid_password?(password) then "Elegí una contraseña distinta a la temporal."
      end

    if error.nil? && current_user.update(password: password, password_confirmation: confirmation, must_change_password: false)
      current_user.user_events.create!(actor: current_user, event_type: "password_changed", created_at: Time.current)
      bypass_sign_in(current_user)
      redirect_to after_sign_in_path_for(current_user), notice: "Listo, tu contraseña quedó guardada."
    else
      flash.now[:alert] = error || current_user.errors.full_messages.join(" ")
      render :edit, status: :unprocessable_entity
    end
  end
end
