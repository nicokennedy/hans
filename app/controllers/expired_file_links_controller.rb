# Los remitos (PNG individual y PDF masivo) se generan en el navegador y se entregan con una
# URL temporal blob:https://<host>/<uuid> que solo existe en la pestaña que los generó. Si esa
# dirección se comparte, se recarga después de liberada o se abre en otro dispositivo, el
# navegador pide https://<host>/<uuid> al servidor, que nunca tuvo ese archivo. En vez de un 404
# genérico, explicamos qué pasó y llevamos a la pantalla estable donde se vuelve a generar.
class ExpiredFileLinksController < ApplicationController
  def show
    render :show, status: :gone
  end
end
