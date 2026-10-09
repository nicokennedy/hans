# Comprobantes adjuntos (factura, ticket, transferencia) de compras, gastos y pagos.
module HasAdministrationAttachments
  extend ActiveSupport::Concern

  included do
    has_many :attachments, -> { without_data.order(:id) }, as: :owner, class_name: "AdministrationAttachment", dependent: :destroy
  end
end
