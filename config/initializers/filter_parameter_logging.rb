# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # Datos personales de compradores minoristas (y de la futura tienda online) fuera de los logs.
  :buyer_name, :buyer_phone, :address, :phone, :reason,
  # Tienda pública (Etapa 4): email y notas del pedido (pueden incluir alergias).
  :email, :notes
]
