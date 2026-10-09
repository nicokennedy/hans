require "test_helper"
require_relative "../../../support/finance_helpers"

# Pantallas del módulo de Administración: proveedores, compras, gastos, pagos, cuentas
# corrientes, resumen y categorías. Todo exclusivamente administrativo.
class Admin::AdministrationScreensTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include FinanceHelpers

  setup do
    setup_finance
    @cook = User.create!(email: "fin-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "FinCustomer#{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "fin-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)
    sign_in @admin
  end

  def pdf_upload(name = "factura.pdf", content = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF")
    Rack::Test::UploadedFile.new(StringIO.new(content), "application/pdf", original_filename: name)
  end

  def purchase_params(items:, **extra)
    { supplier_id: @supplier.id, accrual_on: "2026-10-01", due_on: "2026-10-31", document_type: "factura_a", document_number: "0001-00000123", notes: "Compra semanal",
      discount: "", taxes: "", adjustments: "", items: items, request_token: SecureRandom.uuid }.merge(extra)
  end

  def item_params(description, quantity, unit, price)
    { description: description, quantity: quantity, unit: unit, unit_price: price }
  end

  # --- Autorización ------------------------------------------------------------------------------

  ADMIN_GETS = %i[
    admin_administration_root_path admin_administration_purchases_path new_admin_administration_purchase_path admin_administration_expenses_path new_admin_administration_expense_path
    admin_administration_suppliers_path new_admin_administration_supplier_path admin_administration_payments_path new_admin_administration_payment_path admin_administration_accounts_path
    admin_administration_expense_categories_path new_admin_administration_expense_category_path admin_administration_expense_recurrences_path new_admin_administration_expense_recurrence_path
  ].freeze

  test "el administrador entra a todas las pantallas del módulo" do
    ADMIN_GETS.each do |helper|
      get send(helper)
      assert_response :success, "#{helper} debería abrir"
      assert_select "#administration-nav", count: (helper == :admin_administration_root_path ? 1 : 1)
    end
  end

  test "ninguna pantalla muestra textos de traducción faltante (el locale es no trae nombres de mes ni de fecha)" do
    obligation = make_purchase(100, due_on: Date.new(2026, 12, 1))
    payment = pay(10, obligations: [obligation]).payment
    expense = make_expense(10)
    pay(5, allocations: {})
    pages = ADMIN_GETS.map { |h| send(h) } + [
      admin_administration_purchase_path(obligation), admin_administration_expense_path(expense), admin_administration_supplier_path(@supplier), admin_administration_supplier_account_path(@supplier),
      admin_administration_payment_path(payment), edit_admin_administration_purchase_path(obligation), edit_admin_administration_expense_path(expense), edit_admin_administration_supplier_path(@supplier),
      new_admin_administration_supplier_advance_application_path(@supplier), admin_administration_root_path(year: 2026, month: 10), admin_administration_root_path(month: "all")
    ]

    pages.each do |path|
      get path
      assert_response :success, path
      assert_no_match(/Translation missing|translation missing|\bes\.[a-z_]+\.[a-z_]+/, response.body, "texto sin traducir en #{path}")
    end
    get admin_administration_root_path(month: "10", year: "2026")
    assert_select "#dash-month option[selected]", text: "Octubre"
    assert_match "Octubre 2026", response.body
  end

  test "production, clientes y visitantes no acceden a ninguna pantalla ni acción (incluidas exportaciones)" do
    obligation = make_purchase(100)
    payment = pay(10, obligations: [obligation]).payment
    expense = make_expense(10)
    supplier_path = admin_administration_supplier_path(@supplier)
    reads = ADMIN_GETS.map { |h| send(h) } + [
      admin_administration_purchase_path(obligation), admin_administration_expense_path(expense), supplier_path, admin_administration_supplier_account_path(@supplier),
      admin_administration_supplier_account_path(@supplier, format: :csv), admin_administration_purchases_path(format: :csv), admin_administration_expenses_path(format: :csv),
      admin_administration_payment_path(payment), edit_admin_administration_purchase_path(obligation), admin_administration_purchases_path + "/export",
      new_admin_administration_supplier_advance_application_path(@supplier)
    ]
    writes = [
      [:post, admin_administration_purchases_path, purchase_params(items: { "0" => item_params("X", "1", "un", "100") })],
      [:post, admin_administration_suppliers_path, { supplier: { name: "Hack" } }],
      [:post, admin_administration_payments_path, { supplier_id: @supplier.id, amount: "1", paid_on: Date.current.iso8601, payment_method: "cash" }],
      [:post, void_admin_administration_payment_path(payment), { reason: "x" }],
      [:post, void_admin_administration_purchase_path(obligation), { reason: "x" }],
      [:delete, admin_administration_purchase_path(obligation)],
      [:patch, toggle_active_admin_administration_supplier_path(@supplier)],
      [:post, generate_admin_administration_expense_recurrences_path]
    ]
    before = [Supplier.count, Purchase.count, OutgoingPayment.count, Obligation.count, @supplier.reload.active?, payment.reload.voided?]

    [@cook, @customer_user].each do |user|
      sign_out :user
      sign_in user
      reads.each { |path| get path; assert_response :redirect, "#{user.role} no debería leer #{path}"; assert_no_match(/#{Regexp.escape(@supplier.name)}/, response.body) }
      writes.each { |verb, path, params| send(verb, path, params: params); assert_response :redirect, "#{user.role} no debería #{verb} #{path}" }
    end

    sign_out :user
    reads.each do |path|
      get path
      assert_includes [302, 401], response.status, "un visitante no debería leer #{path}" # los .csv responden 401 en vez de redirigir
      assert_no_match(/#{Regexp.escape(@supplier.name)}/, response.body)
    end
    writes.each { |verb, path, params| send(verb, path, params: params); assert_includes [302, 401], response.status }
    assert_equal before, [Supplier.count, Purchase.count, OutgoingPayment.count, Obligation.count, @supplier.reload.active?, payment.reload.voided?]
  end

  test "el menú lateral tiene Administración solo para el administrador y la sección enlaza a todas las pantallas" do
    get admin_administration_root_path
    assert_select "aside.sidebar-hans a[href=?]", admin_administration_root_path, text: "Administración"
    assert_select "#administration-nav a", count: 7
    ["Resumen", "Compras de mercadería", "Gastos", "Proveedores", "Pagos", "Cuentas corrientes", "Categorías de gastos"].each do |label|
      assert_select "#administration-nav a", text: label
    end

    sign_out :user
    sign_in @cook
    get admin_orders_path
    assert_select "aside.sidebar-hans a", text: "Administración", count: 0
  end

  # --- Proveedores ---------------------------------------------------------------------------------

  test "alta y edición de proveedores, con errores de validación visibles" do
    assert_difference "Supplier.count", 1 do
      post admin_administration_suppliers_path, params: { supplier: { name: "Molino Norte", tax_id: "30-71234567-8", email: "ventas@molino.com", phone: "2235550000", address: "Ruta 2", notes: "Entrega los lunes" } }
    end
    supplier = Supplier.find_by!(name: "Molino Norte")
    assert_redirected_to admin_administration_supplier_path(supplier)
    assert_equal "30712345678", supplier.tax_id

    post admin_administration_suppliers_path, params: { supplier: { name: "", tax_id: "123", email: "x" } }
    assert_response :unprocessable_entity
    assert_select "#form-errors"

    patch admin_administration_supplier_path(supplier), params: { supplier: { name: "Molino Norte S.A.", phone: "111" } }
    assert_redirected_to admin_administration_supplier_path(supplier)
    assert_equal "Molino Norte S.A.", supplier.reload.name

    patch admin_administration_supplier_path(supplier), params: { supplier: { name: "" } }
    assert_response :unprocessable_entity
    assert_equal "Molino Norte S.A.", supplier.reload.name
  end

  test "buscar y filtrar proveedores por estado" do
    inactive = Supplier.create!(name: "Inactivo SRL", active: false)
    get admin_administration_suppliers_path, params: { q: @supplier.name }
    assert_select "tbody tr", count: 1
    assert_match @supplier.name, response.body

    get admin_administration_suppliers_path, params: { status: "inactive" }
    assert_select "tbody tr", count: 1
    assert_match inactive.name, response.body

    get admin_administration_suppliers_path, params: { status: "active" }
    assert_no_match(/Inactivo SRL/, response.body)
  end

  test "un proveedor con movimientos se desactiva, no se borra; sin movimientos se puede borrar" do
    make_purchase(100)

    assert_no_difference "Supplier.count" do
      delete admin_administration_supplier_path(@supplier)
    end
    assert_redirected_to admin_administration_supplier_path(@supplier)
    follow_redirect!
    assert_match "solo desactivar", response.body

    patch toggle_active_admin_administration_supplier_path(@supplier)
    assert_not @supplier.reload.active?
    assert_equal 1, @supplier.obligations.count

    assert_difference "Supplier.count", -1 do
      delete admin_administration_supplier_path(@other_supplier)
    end
  end

  test "la ficha del proveedor muestra compras, pagos, saldo pendiente y accesos a la cuenta corriente" do
    a = make_purchase(100, document_number: "A-1")
    pay(30, obligations: [a], reference: "TRF-77")
    get admin_administration_supplier_path(@supplier)

    assert_response :success
    assert_select "#supplier-pending", text: "$70"
    assert_match "A-1", response.body
    assert_match "Transferencia bancaria", response.body
    assert_select "a[href=?]", admin_administration_supplier_account_path(@supplier), text: "Cuenta corriente"
  end

  # --- Compras ---------------------------------------------------------------------------------------

  test "formulario de compra: proveedor, fecha, comprobante, ítems, adjunto y pago opcional" do
    get new_admin_administration_purchase_path

    assert_select "select[name=supplier_id] option", text: @supplier.name
    assert_select "input[name=accrual_on]"
    assert_select "select[name=document_type] option", minimum: 5
    assert_select "input[name=document_number]"
    assert_select "input[name=due_on]"
    assert_select "input[type=file][name=attachment]"
    assert_select "[data-controller=purchase-items]"
    assert_select "template[data-purchase-items-target=template]"
    assert_select "input[name='items[0][description]']"
    assert_select "select[name='items[0][unit]'] option", minimum: 6
    assert_select "#purchase-total"
    assert_select "input[name=pay_now]"
    assert_no_match(/actualizar costo|actualizar stock/i, response.body, "no hay tildes de costo/stock en la etapa 1")
  end

  test "crear una compra con múltiples ítems calcula subtotales y total exactos, y redirige al detalle" do
    params = purchase_params(
      items: { "0" => item_params("Harina 000", "25", "kg", "850,50"), "1" => item_params("Manteca", "2,5", "kg", "5.200"), "2" => item_params("", "", "un", "") },
      discount: "1.000", taxes: "4.200", adjustments: "-50"
    )

    assert_difference "Purchase.count", 1 do
      assert_difference "PurchaseItem.count", 2 do
        post admin_administration_purchases_path, params: params
      end
    end

    obligation = Obligation.purchases.last
    assert_redirected_to admin_administration_purchase_path(obligation)
    purchase = obligation.source
    assert_equal [2_126_250, 1_300_000], purchase.items.map(&:subtotal_cents)
    assert_equal 3_426_250 - 100_000 + 420_000 - 5_000, obligation.amount_cents
    follow_redirect!
    assert_select "#purchase-items tbody tr", count: 2
    assert_select "#purchase-amount", text: "$37.412,50"
    assert_match "0001-00000123", response.body
  end

  test "compra con errores: no guarda nada y vuelve a mostrar el formulario con lo cargado" do
    params = purchase_params(items: { "0" => item_params("Harina", "abc", "kg", "100"), "1" => item_params("Azúcar", "1.250", "kg", "10") })

    assert_no_difference ["Purchase.count", "PurchaseItem.count", "Obligation.count"] do
      post admin_administration_purchases_path, params: params
    end

    assert_response :unprocessable_entity
    assert_select "#form-errors", text: /Ítem 1: la cantidad no es válida/
    assert_select "#form-errors", text: /Ítem 2: la cantidad no es válida/, count: 1
    assert_select "input[name=document_number][value=?]", "0001-00000123"
    assert_select "input[name='items[0][description]'][value=?]", "Harina"
  end

  test "validaciones de la compra: proveedor, fecha y total positivo" do
    [
      purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, supplier_id: ""),
      purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, accrual_on: "no-es-fecha"),
      purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, due_on: "2026-09-01"),
      purchase_params(items: {}),
      purchase_params(items: { "0" => item_params("X", "1", "un", "0") }),
      purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, discount: "999"),
      purchase_params(items: { "0" => item_params("X", "1", "parsec", "100") })
    ].each do |params|
      post admin_administration_purchases_path, params: params
      assert_response :unprocessable_entity, "debería rechazar #{params.except(:items).inspect}"
    end
    assert_equal 0, Purchase.count
  end

  test "comprobante adjunto: se guarda en la base y se descarga solo con sesión de administrador" do
    params = purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, attachment: pdf_upload)

    assert_difference "AdministrationAttachment.count", 1 do
      post admin_administration_purchases_path, params: params
    end

    attachment = AdministrationAttachment.last
    assert_equal "application/pdf", attachment.content_type
    assert_equal "factura.pdf", attachment.filename
    assert_equal Obligation.purchases.last.source, attachment.owner
    follow_redirect!
    assert_select "#attachments a", text: "factura.pdf"

    get admin_administration_attachment_path(attachment)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert response.body.start_with?("%PDF")

    sign_out :user
    get admin_administration_attachment_path(attachment)
    assert_redirected_to new_user_session_path
    sign_in @cook
    get admin_administration_attachment_path(attachment)
    assert_response :redirect
  end

  test "adjuntos inválidos (tipo falso, ejecutable, demasiado grande) se rechazan sin crear la compra" do
    fake_pdf = Rack::Test::UploadedFile.new(StringIO.new("MZ\x90\x00 esto es un ejecutable"), "application/pdf", original_filename: "malo.pdf")
    huge = pdf_upload("grande.pdf", "%PDF-1.4\n" + ("x" * (AdministrationAttachment::MAX_BYTES + 10)))

    [fake_pdf, huge].each do |upload|
      assert_no_difference ["Purchase.count", "AdministrationAttachment.count"] do
        post admin_administration_purchases_path, params: purchase_params(items: { "0" => item_params("X", "1", "un", "100") }, attachment: upload)
      end
      assert_response :unprocessable_entity
      assert_select "#form-errors", text: /Comprobante/
    end
  end

  test "pagar al cargar la compra (total y parcial); un pago mayor al total se rechaza y no crea la compra" do
    post admin_administration_purchases_path, params: purchase_params(items: { "0" => item_params("X", "1", "un", "1.000") }, pay_now: "1", pay_amount: "400", pay_method: "cash", pay_paid_on: Date.current.iso8601, pay_reference: "R-1")
    obligation = Obligation.purchases.last
    assert_equal pesos(600), obligation.balance_cents
    assert_equal :partial, obligation.status
    assert_equal "R-1", OutgoingPayment.last.reference

    assert_no_difference ["Purchase.count", "OutgoingPayment.count"] do
      post admin_administration_purchases_path, params: purchase_params(items: { "0" => item_params("X", "1", "un", "1.000") }, pay_now: "1", pay_amount: "1.001", pay_method: "cash", pay_paid_on: Date.current.iso8601)
    end
    assert_response :unprocessable_entity
  end

  test "editar una compra y su detalle conserva el historial; ver, anular y eliminar" do
    obligation = make_purchase(100)
    purchase = obligation.source
    item = purchase.items.first

    get edit_admin_administration_purchase_path(obligation)
    assert_response :success
    assert_select "input[name='items[0][id]'][value=?]", item.id.to_s

    patch admin_administration_purchase_path(obligation), params: purchase_params(items: { "0" => item_params("Mercadería editada", "2", "kg", "60").merge(id: item.id) })
    assert_redirected_to admin_administration_purchase_path(obligation)
    assert_equal item.id, purchase.reload.items.first.id
    assert_equal pesos(120), obligation.reload.amount_cents

    post void_admin_administration_purchase_path(obligation), params: { reason: "" }
    assert_not obligation.reload.voided?
    post void_admin_administration_purchase_path(obligation), params: { reason: "Compra duplicada" }
    assert obligation.reload.voided?
    follow_redirect!
    assert_match "Motivo: Compra duplicada", response.body

    free = make_purchase(10)
    assert_difference "Purchase.count", -1 do
      delete admin_administration_purchase_path(free)
    end
    paid = make_purchase(10)
    pay(5, obligations: [paid])
    assert_no_difference "Purchase.count" do
      delete admin_administration_purchase_path(paid)
    end
  end

  test "listado de compras: columnas, estados y filtros por fecha, proveedor, estado y comprobante" do
    a = make_purchase(100, accrual_on: Date.new(2026, 10, 1), document_type: "factura_a", document_number: "A-1", due_on: Date.new(2026, 10, 20))
    b = make_purchase(200, accrual_on: Date.new(2026, 9, 1), document_type: "remito", document_number: "R-1")
    c = make_purchase(300, supplier: @other_supplier, accrual_on: Date.new(2026, 10, 5), document_type: "factura_b", document_number: "B-1")
    pay(100, obligations: [a])
    pay(50, obligations: [b])

    get admin_administration_purchases_path
    assert_response :success
    assert_select "thead th", text: "Saldo"
    assert_equal ["Parcialmente pagado", "Pagado", "Pendiente"].sort, css_select("tbody tr td .badge").map(&:text).map(&:strip).reject { |t| t == "Vencida" }.sort
    assert_select "#purchases-totals", text: /3 compras/

    listed = ->(params) { get admin_administration_purchases_path, params: params; css_select("tbody tr").size }
    assert_equal 2, listed.({ from: "2026-10-01" })
    assert_equal 1, listed.({ to: "2026-09-30" })
    assert_equal 2, listed.({ supplier_id: @supplier.id })
    assert_equal 1, listed.({ status: "paid" })
    assert_equal 1, listed.({ status: "partial" })
    assert_equal 1, listed.({ status: "pending" })
    assert_equal 1, listed.({ document_type: "remito" })
    assert_equal 1, listed.({ supplier_id: @supplier.id, status: "paid", from: "2026-10-01", document_type: "factura_a" })
    assert_equal 3, listed.({ status: "inválido", from: "basura", document_type: "<x>" })
  end

  test "exportar compras a CSV respeta los filtros, y la acción export redirige" do
    make_purchase(100, document_number: "CSV-1", notes: "=1+1")
    make_purchase(50, supplier: @other_supplier, document_number: "CSV-2")

    get admin_administration_purchases_path(format: :csv, supplier_id: @supplier.id)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match(/attachment; filename="compras-/, response.headers["Content-Disposition"])
    rows = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_equal ["CSV-1"], rows.map { |r| r["Número"] }
    assert_equal "'=1+1", rows.first["Comentario"]

    get export_admin_administration_purchases_path(supplier_id: @supplier.id)
    assert_redirected_to admin_administration_purchases_path(supplier_id: @supplier.id, format: :csv)
  end

  # --- Gastos y categorías ---------------------------------------------------------------------------

  test "registrar un gasto con y sin proveedor, con pago inmediato, y listarlo con filtros" do
    post admin_administration_expenses_path, params: { expense_category_id: @category.id, amount: "120.000", accrual_on: "2026-10-01", due_on: "2026-10-10", document_type: "boleta", document_number: "B-9", notes: "Luz",
                                                       request_token: SecureRandom.uuid }
    obligation = Obligation.expenses.last
    assert_redirected_to admin_administration_expense_path(obligation)
    assert_nil obligation.supplier_id
    assert_equal pesos(120_000), obligation.amount_cents

    post admin_administration_expenses_path, params: { expense_category_id: @category.id, supplier_id: @supplier.id, amount: "500", accrual_on: "2026-10-02", pay_now: "1", pay_amount: "500", pay_method: "cash", pay_paid_on: Date.current.iso8601, request_token: SecureRandom.uuid }
    assert_equal :paid, Obligation.expenses.last.status

    get admin_administration_expenses_path, params: { category_id: @category.id, status: "pending" }
    assert_select "tbody tr", count: 1
    assert_select "#expenses-totals", text: /1 gastos/

    post admin_administration_expenses_path, params: { expense_category_id: "", amount: "abc", accrual_on: "" }
    assert_response :unprocessable_entity
    assert_select "#form-errors"
  end

  test "exportar gastos a CSV" do
    make_expense(100)
    get admin_administration_expenses_path(format: :csv)
    rows = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_equal ["Fecha", "Categoría", "Proveedor", "Tipo de comprobante", "Número", "Importe", "Pagado", "Saldo", "Estado", "Vencimiento", "Comentario"], rows.headers
    assert_equal @category.name, rows.first["Categoría"]
    assert_equal "100.00", rows.first["Importe"]
  end

  test "categorías de gastos: alta, edición, desactivación; una categoría desactivada no se ofrece pero conserva sus gastos" do
    post admin_administration_expense_categories_path, params: { expense_category: { name: "Seguros", position: 5, active: "1" } }
    category = ExpenseCategory.find_by!(name: "Seguros")
    assert_redirected_to admin_administration_expense_categories_path

    post admin_administration_expense_categories_path, params: { expense_category: { name: "seguros" } }
    assert_response :unprocessable_entity

    patch admin_administration_expense_category_path(category), params: { expense_category: { name: "Seguros y fianzas" } }
    assert_equal "Seguros y fianzas", category.reload.name

    make_expense(10, category: category)
    patch toggle_active_admin_administration_expense_category_path(category)
    assert_not category.reload.active?
    get new_admin_administration_expense_path
    assert_select "select[name=expense_category_id] option", text: "Seguros y fianzas", count: 0
    get admin_administration_expenses_path
    assert_match "Seguros y fianzas", response.body
  end

  test "gastos recurrentes: crear genera ocurrencias vencidas, no se duplican, y se pueden desactivar" do
    assert_difference "ExpenseRecurrence.count", 1 do
      post admin_administration_expense_recurrences_path, params: { expense_recurrence: { expense_category_id: @category.id, amount: "80.000", frequency: "monthly", starts_on: (Date.current << 2).iso8601, due_days: "5", notes: "Alquiler" } }
    end
    recurrence = ExpenseRecurrence.last
    assert_redirected_to admin_administration_expense_recurrences_path
    generated = Expense.where(expense_recurrence: recurrence).count
    assert_operator generated, :>=, 3

    post generate_admin_administration_expense_recurrences_path
    get admin_administration_expenses_path
    assert_equal generated, Expense.where(expense_recurrence: recurrence).count

    post deactivate_admin_administration_expense_recurrence_path(recurrence)
    assert_not recurrence.reload.active?
    assert_equal generated, Expense.where(expense_recurrence: recurrence).count

    post admin_administration_expense_recurrences_path, params: { expense_recurrence: { expense_category_id: @category.id, amount: "", frequency: "monthly", starts_on: Date.current.iso8601 } }
    assert_response :unprocessable_entity
  end

  # --- Pagos ---------------------------------------------------------------------------------------------

  test "formulario de pago: proveedor, importe, fecha, medio, referencia, comentario, adjunto y obligaciones ordenadas por vencimiento" do
    late = make_purchase(100, due_on: Date.new(2026, 11, 1), document_number: "LATE")
    early = make_purchase(100, due_on: Date.new(2026, 10, 10), document_number: "EARLY")

    get new_admin_administration_payment_path(supplier_id: @supplier.id)

    assert_response :success
    assert_select "input[name=amount]"
    assert_select "input[name=paid_on]"
    assert_select "select[name=payment_method] option", count: 6
    assert_select "input[name=reference]"
    assert_select "input[type=file][name=attachment]"
    assert_equal [early.id, late.id].map(&:to_s), css_select("tr[data-payment-distribution-target=row]").map { |tr| tr["data-order-id"] }
    assert_select "#payment-preview"
    assert_match "Importe pagado − Importe imputado = Sin imputar", response.body
  end

  test "registrar un pago de $300.000 que cancela varias facturas con la imputación propuesta" do
    a = make_purchase(100_000, due_on: Date.new(2026, 10, 10))
    b = make_purchase(150_000, due_on: Date.new(2026, 10, 20))
    c = make_purchase(200_000, due_on: Date.new(2026, 10, 30))
    params = { supplier_id: @supplier.id, amount: "300.000", paid_on: Date.current.iso8601, payment_method: "bank_transfer", reference: "OP 123", note: "Pago semanal", request_token: SecureRandom.uuid,
               allocations: { a.id => "100.000", b.id => "150.000", c.id => "50.000" }, attachment: pdf_upload("comprobante.pdf") }

    assert_difference "OutgoingPayment.count", 1 do
      assert_difference "OutgoingPaymentApplication.count", 3 do
        assert_difference "AdministrationAttachment.count", 1 do
          post admin_administration_payments_path, params: params
        end
      end
    end

    payment = OutgoingPayment.last
    assert_redirected_to admin_administration_payment_path(payment)
    assert_equal [0, 0, pesos(150_000)], balances(a, b, c)
    assert_equal @admin, payment.user
    follow_redirect!
    assert_select "#payment-applied", text: "$300.000"
    assert_select "#payment-advance", text: "$0"
    assert_match "OP 123", response.body
  end

  test "pago parcial, pago mayor a la deuda (anticipo) y pago con edición manual" do
    a = make_purchase(100)
    post admin_administration_payments_path, params: { supplier_id: @supplier.id, amount: "40", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { a.id => "40" }, request_token: SecureRandom.uuid }
    assert_equal pesos(60), Obligation.find(a.id).balance_cents

    post admin_administration_payments_path, params: { supplier_id: @supplier.id, amount: "100", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { a.id => "60" }, request_token: SecureRandom.uuid }
    assert_redirected_to admin_administration_payment_path(OutgoingPayment.last)
    follow_redirect!
    assert_match "Quedaron $40 como anticipo", response.body
    assert_equal pesos(40), @supplier.reload.advance_cents
  end

  test "pagos con importes inválidos o que superan saldos: errores y nada guardado" do
    a = make_purchase(100)
    [
      { amount: "abc", allocations: { a.id => "10" } },
      { amount: "", allocations: {} },
      { amount: "100", allocations: { a.id => "101" } },
      { amount: "50", allocations: { a.id => "60" } },
      { amount: "100", allocations: { a.id => "-5" } },
      { amount: "100", allocations: { a.id => "uno" } },
      { amount: "100", allocations: { a.id => "10" }, paid_on: "no-es-fecha" },
      { amount: "100", allocations: { a.id => "10" }, payment_method: "trueque" }
    ].each do |overrides|
      post admin_administration_payments_path, params: { supplier_id: @supplier.id, paid_on: Date.current.iso8601, payment_method: "cash", request_token: SecureRandom.uuid }.merge(overrides)
      assert_response :unprocessable_entity, "debería rechazar #{overrides.inspect}"
      assert_select "#form-errors"
    end
    assert_equal 0, OutgoingPayment.count
    assert_equal pesos(100), Obligation.find(a.id).balance_cents
  end

  test "no se puede imputar a obligaciones de otro proveedor por manipulación del formulario" do
    foreign = make_purchase(100, supplier: @other_supplier)

    post admin_administration_payments_path, params: { supplier_id: @supplier.id, amount: "100", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { foreign.id => "100" }, request_token: SecureRandom.uuid }

    assert_response :unprocessable_entity
    assert_match "no corresponde a este proveedor", response.body
    assert_equal pesos(100), Obligation.find(foreign.id).balance_cents
  end

  test "el reenvío del mismo formulario no duplica el pago" do
    a = make_purchase(100)
    params = { supplier_id: @supplier.id, amount: "40", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { a.id => "40" }, request_token: SecureRandom.uuid }

    2.times { post admin_administration_payments_path, params: params }

    assert_equal 1, OutgoingPayment.count
    assert_equal pesos(60), Obligation.find(a.id).balance_cents
    follow_redirect!
    assert_match "ya estaba registrado", response.body
  end

  test "el botón Pagar de una compra o gasto precarga el importe y la imputación de esa obligación" do
    a = make_purchase(100)
    make_purchase(50, accrual_on: Date.new(2026, 8, 1), due_on: Date.new(2026, 9, 1))
    expense = make_expense(70)

    get new_admin_administration_payment_path(supplier_id: @supplier.id, obligation_id: a.id)
    assert_select "input[name=amount][value=?]", "100"
    assert_select "input[name='allocations[#{a.id}]'][value=?]", "100"

    get new_admin_administration_payment_path(supplier_id: "none", obligation_id: expense.id)
    assert_select "tr[data-order-id=?]", expense.id.to_s
    assert_select "input[name='allocations[#{expense.id}]'][value=?]", "70"
  end

  test "pago de un gasto sin proveedor, completo" do
    expense = make_expense(70)

    post admin_administration_payments_path, params: { supplier_id: "none", amount: "70", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { expense.id => "70" }, request_token: SecureRandom.uuid }

    assert_redirected_to admin_administration_payment_path(OutgoingPayment.last)
    assert_equal :paid, Obligation.find(expense.id).status
    assert_nil OutgoingPayment.last.supplier_id

    other = make_expense(70)
    post admin_administration_payments_path, params: { supplier_id: "none", amount: "100", paid_on: Date.current.iso8601, payment_method: "cash", allocations: { other.id => "70" }, request_token: SecureRandom.uuid }
    assert_response :unprocessable_entity
    assert_match "no admite anticipos", response.body
  end

  test "anular un pago: pide motivo, conserva el registro y restablece saldos; historial de pagos" do
    a = make_purchase(100)
    payment = pay(100, obligations: [a]).payment

    post void_admin_administration_payment_path(payment), params: { reason: "" }
    assert_not payment.reload.voided?
    post void_admin_administration_payment_path(payment), params: { reason: "Transferencia duplicada" }
    assert payment.reload.voided?
    assert_equal pesos(100), Obligation.find(a.id).balance_cents
    follow_redirect!
    assert_match "Motivo: Transferencia duplicada", response.body

    get admin_administration_payments_path
    assert_select "tbody tr", count: 1
    assert_match "Anulado", response.body
    get admin_administration_payments_path, params: { status: "active" }
    assert_select "tbody tr", count: 0
  end

  test "aplicar anticipos desde la cuenta corriente y revertirlos" do
    pay(100, allocations: {})
    later = make_purchase(60)

    get new_admin_administration_supplier_advance_application_path(@supplier)
    assert_select "[data-payment-distribution-fixed-amount-value=?]", pesos(100).to_s

    post admin_administration_supplier_advance_applications_path(@supplier), params: { allocations: { later.id => "60" } }
    assert_redirected_to admin_administration_supplier_account_path(@supplier)
    follow_redirect!
    assert_match "Te quedan $40 de anticipo", response.body
    assert_equal 0, Obligation.find(later.id).balance_cents

    application = OutgoingPaymentApplication.find_by(kind: "advance")
    post revert_admin_administration_supplier_advance_application_path(@supplier, application), params: { reason: "Factura equivocada" }
    assert application.reload.voided?
    assert_equal pesos(60), Obligation.find(later.id).balance_cents

    post admin_administration_supplier_advance_applications_path(@supplier), params: { allocations: { later.id => "999" } }
    assert_response :unprocessable_entity
  end

  # --- Cuentas corrientes y resumen ------------------------------------------------------------------

  test "cuenta corriente del proveedor: ecuación, anticipos por separado, movimientos cronológicos y filtro de fechas" do
    a = make_purchase(100, accrual_on: Date.new(2026, 9, 1))
    make_purchase(50, accrual_on: Date.new(2026, 10, 1))
    pay(120, obligations: Finance::Distribution.pending_obligations(@supplier).to_a, paid_on: Date.new(2026, 9, 10))
    pay(30, allocations: {}, paid_on: Date.new(2026, 9, 20))

    get admin_administration_supplier_account_path(@supplier)

    assert_response :success
    assert_select "#acc-total", text: "$150"
    assert_select "#acc-applied", text: "$120"
    assert_select "#acc-pending", text: "$30"
    assert_select "#acc-advance", text: "$30"
    assert_select "#acc-net", text: "$0"
    assert_select "#account-entries article", count: 4
    assert_select "a#apply-advance"
    dates = css_select("#account-entries article > div:first-child .text-muted.small").map(&:text).map { |t| t[%r{\d\d/\d\d/\d{4}}] }
    assert_equal dates.map { |d| Date.strptime(d, "%d/%m/%Y") }.sort, dates.map { |d| Date.strptime(d, "%d/%m/%Y") }

    get admin_administration_supplier_account_path(@supplier, from: "2026-09-15", to: "2026-09-30")
    assert_select "#account-entries article", count: 1
    assert_select "#acc-total", text: "$150", count: 1
  end

  test "la cuenta corriente se exporta a CSV y el listado general muestra saldos por proveedor" do
    make_purchase(100)
    make_purchase(300, supplier: @other_supplier)
    pay(50, supplier: @other_supplier, allocations: {})

    get admin_administration_supplier_account_path(@supplier, format: :csv)
    assert_response :success
    rows = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_equal ["Compra"], rows.map { |r| r["Tipo"] }
    assert_match(/cuenta-corriente-/, response.headers["Content-Disposition"])

    get admin_administration_accounts_path
    assert_select "#accounts-pending", text: "$400"
    assert_select "#accounts-advances", text: "$50"
    assert_select "tbody tr", count: 2
    get admin_administration_accounts_path, params: { q: @other_supplier.name }
    assert_select "tbody tr", count: 1
  end

  test "resumen: indicadores del período, vencidas, próximas a vencer, categorías y proveedores" do
    travel_to Time.zone.local(2026, 10, 15, 12) do
      make_purchase(100, accrual_on: Date.new(2026, 10, 2), due_on: Date.new(2026, 10, 10))
      make_purchase(40, accrual_on: Date.new(2026, 10, 3), due_on: Date.new(2026, 10, 20))
      make_expense(30, accrual_on: Date.new(2026, 10, 5))
      pay(40, paid_on: Date.new(2026, 10, 8), obligations: [Obligation.purchases.order(:id).last])

      get admin_administration_root_path, params: { year: "2026", month: "10" }

      assert_response :success
      assert_select "#kpi-purchases", text: "$140"
      assert_select "#kpi-expenses", text: "$30"
      assert_select "#kpi-paid", text: "$40"
      assert_select "#kpi-pending", text: "$130"
      assert_select "#kpi-overdue", text: "$100"
      assert_select "#expenses-by-category tbody tr", count: 1
      assert_select "#top-suppliers tbody tr", count: 1
      assert_select "#supplier-balances tbody tr", count: 1
      assert_no_match(/resultado|ganancia/i, css_select("#dashboard-kpis").to_s)

      get admin_administration_root_path, params: { year: "2026", month: "9" }
      assert_select "#kpi-purchases", text: "$0"
      get admin_administration_root_path, params: { year: "2026", month: "all" }
      assert_select "#kpi-purchases", text: "$140"
      get admin_administration_root_path, params: { year: "basura", month: "99" }
      assert_response :success
    end
  end

  # --- Etapa 1: sin impacto operativo ------------------------------------------------------------------

  test "ninguna pantalla ni acción del módulo modifica stock, materias primas, recetas ni costos" do
    raw = RawMaterial.create!(name: "Harina 000", purchase_price_cents: 100_000, purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg", supplier: "Molino")
    prep = Preparation.create!(name: "Masa", yield_quantity: 1, yield_unit: "kg")
    prep.recipe_components.create!(component: raw, quantity: 1, unit: "kg")
    product = Product.create!(name: "Alfajor", category: Category.create!(name: "C#{rand(100_000)}", position: 1, active: true), price_cents: 500, cost_cents: 200, active: true, position: 1)
    StockItem.create!(stockable: product, active: true, quantity: 7, minimum_quantity: 3, stock_tracking_started_on: Date.new(2026, 1, 1))
    before = untouchable_snapshot

    post admin_administration_purchases_path, params: purchase_params(items: { "0" => item_params("Harina 000", "50", "kg", "1.500") }, pay_now: "1", pay_amount: "1.000", pay_method: "cash", pay_paid_on: Date.current.iso8601)
    obligation = Obligation.purchases.last
    patch admin_administration_purchase_path(obligation), params: purchase_params(items: { "0" => item_params("Harina 000", "60", "kg", "1.600").merge(id: obligation.source.items.first.id) })
    post admin_administration_payments_path, params: { supplier_id: @supplier.id, amount: "500", paid_on: Date.current.iso8601, payment_method: "cash", allocations: {}, request_token: SecureRandom.uuid }
    post admin_administration_expenses_path, params: { expense_category_id: @category.id, amount: "100", accrual_on: "2026-10-01", request_token: SecureRandom.uuid }
    get admin_administration_root_path
    get admin_administration_supplier_account_path(@supplier)
    get admin_administration_purchases_path(format: :csv)

    assert_equal before, untouchable_snapshot
    assert_nil PurchaseItem.last.raw_material_id
    assert_equal 100_000, raw.reload.purchase_price_cents
    assert_equal 0, RawMaterialCostChange.count
    assert_equal 0, StockMovement.count
  end
end
