module DeliveryRoutes
  # Quién puede cambiar cobros, gastos y fotos de un recorrido, y en qué estado.
  module Access
    module_function

    # Devuelve nil si puede, o el mensaje para mostrar.
    def money_error(route, user)
      if user&.admin?
        route.open_for_admin? ? nil : "La rendición ya está cerrada: las correcciones se hacen desde la cuenta corriente del cliente."
      elsif user&.driver? && route.driver_id == user.id
        route.open_for_driver? ? nil : "Ya enviaste la rendición: no se puede cambiar. Si hay un error, avisale a administración."
      else
        "No tenés permiso para registrar en este recorrido."
      end
    end
  end
end
