# Historial de Administración → Usuarios: quién creó, editó, cambió el rol, activó o desactivó
# a un usuario o le restableció la contraseña. Solo inserción. Nunca guarda contraseñas.
class UserEvent < ApplicationRecord
  LABELS = {
    "created" => "Creó el usuario", "updated" => "Editó los datos", "role_changed" => "Cambió el rol",
    "deactivated" => "Desactivó el acceso", "activated" => "Activó el acceso",
    "password_reset" => "Restableció la contraseña", "password_changed" => "Cambió su contraseña temporal"
  }.freeze

  belongs_to :user
  belongs_to :actor, class_name: "User"

  validates :event_type, inclusion: { in: LABELS.keys }

  before_update { raise ActiveRecord::ReadOnlyRecord, "El historial de usuarios no se modifica." }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "El historial de usuarios no se borra." }

  def label
    LABELS.fetch(event_type, event_type)
  end
end
