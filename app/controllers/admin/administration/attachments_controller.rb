# Descarga de comprobantes. Solo admin; el archivo se sirve con su tipo ya validado.
class Admin::Administration::AttachmentsController < Admin::Administration::BaseController
  def show
    attachment = AdministrationAttachment.find(params[:id])
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data attachment.data, filename: attachment.filename, type: attachment.content_type, disposition: params[:download] == "1" ? "attachment" : "inline"
  end
end
