module AdministrationHelper
  ADMIN_SECTIONS = [
    ["Resumen", :admin_administration_root_path, "admin/administration/dashboard"],
    ["Compras de mercadería", :admin_administration_purchases_path, "admin/administration/purchases"],
    ["Gastos", :admin_administration_expenses_path, "admin/administration/expenses"],
    ["Proveedores", :admin_administration_suppliers_path, "admin/administration/suppliers"],
    ["Pagos", :admin_administration_payments_path, "admin/administration/payments"],
    ["Cuentas corrientes", :admin_administration_accounts_path, "admin/administration/supplier_accounts"],
    ["Categorías de gastos", :admin_administration_expense_categories_path, "admin/administration/expense_categories"]
  ].freeze

  def fin_money(cents)
    "$#{Finance::Money.format_pesos(cents.to_i)}"
  end

  def administration_nav_class
    "btn btn-sm #{params[:controller].to_s.start_with?('admin/administration/') ? 'btn-dark' : 'btn-outline-dark'}"
  end

  def administration_section_class(controller_path)
    current = params[:controller].to_s
    active = current == controller_path || (controller_path == "admin/administration/suppliers" && current == "admin/administration/advance_applications") ||
             (controller_path == "admin/administration/expenses" && current == "admin/administration/expense_recurrences")
    "btn btn-sm #{active ? 'btn-dark' : 'btn-outline-dark'}"
  end

  STATUS_BADGES = { paid: "bg-success", partial: "bg-warning text-dark", pending: "bg-secondary", voided: "bg-dark" }.freeze

  def obligation_status_badge(obligation)
    content_tag(:span, obligation.status_label, class: "badge #{STATUS_BADGES[obligation.status]}") +
      (obligation.overdue? ? content_tag(:span, "Vencida", class: "badge bg-danger ms-1") : "".html_safe)
  end

  def document_type_options
    Obligation::DOCUMENT_TYPES.map { |key, label| [label, key] }
  end

  def unit_options
    PurchaseItem::UNITS.map { |unit| [PurchaseItem.unit_label(unit), unit] }
  end

  def payment_method_options
    OutgoingPayment::METHODS.map { |key, label| [label, key] }
  end

  def date_label(date)
    date&.strftime("%d/%m/%Y") || "—"
  end
end
