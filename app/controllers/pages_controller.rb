class PagesController < ApplicationController
  def home
    # El ícono de HANS en la pantalla de inicio del iPhone abre "/": el repartidor va
    # directo a su reparto, sin pasar por la portada del portal mayorista.
    redirect_to reparto_root_path if user_signed_in? && current_user.driver?
  end
end
