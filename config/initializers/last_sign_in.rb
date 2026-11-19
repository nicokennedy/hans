# Administración → Usuarios: guarda la fecha y hora del último inicio de sesión exitoso (con
# contraseña o con el "recordarme" del celular). Sin IP ni otros datos. No toca updated_at.
Warden::Manager.after_authentication do |user, _auth, _opts|
  user.update_column(:last_sign_in_at, Time.current) if user.is_a?(User) && user.persisted?
end
