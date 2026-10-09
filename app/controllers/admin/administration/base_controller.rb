# Base de todo el módulo de Administración: exclusivamente administrativo (el perfil
# production y los clientes del portal no pueden verlo).
class Admin::Administration::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  PER_PAGE = 50

  private

  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Importe en pesos -> centavos; nil si está vacío; false si es inválido.
  def parse_pesos(value, blank: nil)
    return blank if value.to_s.strip.empty?

    Finance::Money.parse_pesos(value) || false
  end

  # Pagina un scope: define @page y @total_pages y devuelve el scope de la página.
  def paginate(scope)
    total = scope.count
    @total_count = total
    @total_pages = [(total.to_f / PER_PAGE).ceil, 1].max
    @page = [[params[:page].to_i, 1].max, @total_pages].min
    scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def upload_param(key = :attachment)
    upload = params[key]
    upload.respond_to?(:read) ? upload : nil
  end

  def attachment_errors(upload)
    return [] unless upload

    attachment = AdministrationAttachment.build_from_upload(Purchase.new, upload)
    attachment.valid? ? [] : attachment.errors.full_messages.map { |m| "Comprobante: #{m}" }
  ensure
    upload&.rewind
  end
end
