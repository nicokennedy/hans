module Users
  # Administración → Usuarios: altas, ediciones, roles, accesos y contraseñas de los usuarios
  # INTERNOS (administrador, producción, repartidor). Las cuentas de clientes no se tocan acá.
  # Resguardos: nadie se quita su propio rol ni se desactiva; HANS nunca queda sin un
  # administrador activo; un repartidor con recorridos pendientes no cambia de rol. Todo queda
  # en UserEvent con quién lo hizo. Nunca guarda contraseñas legibles: la temporal se devuelve
  # una sola vez en el resultado.
  class Manage
    Result = Struct.new(:user, :password, :errors, :warnings, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    def initialize(actor)
      @actor = actor
    end

    def create(name:, email:, role:)
      role = role.to_s
      return failure(User.new, "Elegí un rol válido: administrador, producción o repartidor.") unless User::INTERNAL_ROLES.include?(role)

      password = TemporaryPassword.generate
      user = User.new(name: name.to_s.squish.presence, email: email.to_s.strip.downcase, role: role,
                      password: password, password_confirmation: password, must_change_password: true, active: true)
      User.transaction do
        user.save!
        record(user, "created", role: role, email: user.email, name: user.name)
      end
      Result.new(user: user, password: password, errors: [], warnings: [])
    rescue ActiveRecord::RecordInvalid
      Result.new(user: user, errors: user.errors.full_messages, warnings: [])
    end

    def update(user, name:, email:, role:)
      return failure(user, "Las cuentas de clientes se administran desde Clientes.") unless user.internal?

      role = role.to_s
      errors = []
      errors << "Elegí un rol válido: administrador, producción o repartidor." unless User::INTERNAL_ROLES.include?(role)
      if role != user.role
        errors << "No podés cambiar tu propio rol." if user == @actor
        errors << "#{user.display_name} es el último administrador activo: HANS no puede quedar sin administradores." if user.admin? && last_active_admin?(user)
        if user.driver? && (pending = pending_routes(user)).any?
          errors << "#{user.display_name} tiene recorridos pendientes (#{pending.map { |r| I18n.l(r.date, format: '%d/%m') }.join(', ')}). Reasignalos antes de cambiarle el rol."
        end
      end
      return failure(user, *errors) if errors.any?

      before = user.slice(:name, :email, :role)
      user.assign_attributes(name: name.to_s.squish.presence, email: email.to_s.strip.downcase, role: role)
      return Result.new(user: user, errors: [], warnings: []) unless user.changed?

      User.transaction do
        user.save!
        data_changes = user.saved_changes.slice("name", "email").transform_values { |from, to| { "from" => from, "to" => to } }
        record(user, "updated", changes: data_changes) if data_changes.any?
        record(user, "role_changed", from: before["role"], to: user.role) if user.saved_change_to_role?
      end
      Result.new(user: user, errors: [], warnings: [])
    rescue ActiveRecord::RecordInvalid
      Result.new(user: user, errors: user.errors.full_messages, warnings: [])
    end

    def set_active(user, active)
      return failure(user, "Las cuentas de clientes se administran desde Clientes.") unless user.internal?
      return Result.new(user: user, errors: [], warnings: []) if user.active? == active

      unless active
        return failure(user, "No podés desactivar tu propio acceso.") if user == @actor
        return failure(user, "#{user.display_name} es el último administrador activo: HANS no puede quedar sin administradores.") if user.admin? && last_active_admin?(user)
      end

      warnings = []
      if !active && user.driver? && (pending = pending_routes(user)).any?
        warnings << "#{user.display_name} tiene recorridos pendientes (#{pending.map { |r| I18n.l(r.date, format: '%d/%m') }.join(', ')}): reasignalos a otro repartidor."
      end
      User.transaction do
        user.update!(active: active)
        record(user, active ? "activated" : "deactivated")
      end
      Result.new(user: user, errors: [], warnings: warnings)
    end

    # Genera una contraseña temporal nueva. Cambiar la contraseña invalida las sesiones abiertas
    # y el "recordarme" del usuario (Devise los firma con el hash de la contraseña).
    def reset_password(user)
      return failure(user, "Las cuentas de clientes se administran desde Clientes.") unless user.internal?
      return failure(user, "No podés restablecer tu propia contraseña desde acá.") if user == @actor

      password = TemporaryPassword.generate
      User.transaction do
        user.update!(password: password, password_confirmation: password, must_change_password: true)
        record(user, "password_reset")
      end
      Result.new(user: user, password: password, errors: [], warnings: [])
    end

    private

    def record(user, type, **data)
      user.user_events.create!(actor: @actor, event_type: type, data: data, created_at: Time.current)
    end

    def failure(user, *errors)
      Result.new(user: user, errors: errors, warnings: [])
    end

    def last_active_admin?(user)
      User.where(role: "admin", active: true).where.not(id: user.id).none?
    end

    def pending_routes(user)
      DeliveryRoute.where(driver: user).where("date >= ?", Date.current).order(:date).to_a
    end
  end
end
