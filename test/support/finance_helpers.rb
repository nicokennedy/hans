# Datos comunes de los tests del módulo de Administración. Importes en centavos.
module FinanceHelpers
  def setup_finance
    @admin = User.create!(email: "fin-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @supplier = Supplier.create!(name: "Distribuidora Norte #{rand(1_000_000)}")
    @other_supplier = Supplier.create!(name: "Otro Proveedor #{rand(1_000_000)}")
    @category = ExpenseCategory.create!(name: "Servicios #{rand(1_000_000)}")
  end

  def pesos(amount)
    amount * 100
  end

  def purchase_items(*rows)
    rows = [{ description: "Harina 000", quantity: BigDecimal("1"), unit: "kg", unit_price_cents: 100_000 }] if rows.empty?
    rows
  end

  # Compra de `amount` pesos en un solo ítem (cantidad 1 x precio).
  def make_purchase(amount, supplier: @supplier, accrual_on: Date.new(2026, 10, 1), due_on: nil, document_type: "factura_a", document_number: nil, user: @admin, **extra)
    result = Finance::SavePurchase.call(
      user: user, purchase: nil,
      attributes: { supplier_id: supplier.id, accrual_on: accrual_on, due_on: due_on, document_type: document_type, document_number: document_number, notes: extra[:notes] },
      totals: { discount_cents: 0, taxes_cents: 0, adjustments_cents: 0 },
      items: [{ description: "Mercadería", quantity: BigDecimal("1"), unit: "un", unit_price_cents: pesos(amount) }]
    )
    raise "no se pudo crear la compra: #{result.errors.inspect}" unless result.ok?

    result.record.obligation
  end

  def make_expense(amount, supplier: nil, category: @category, accrual_on: Date.new(2026, 10, 1), due_on: nil, user: @admin)
    result = Finance::SaveExpense.call(user: user, attributes: { supplier_id: supplier&.id, expense_category_id: category.id, amount_cents: pesos(amount), accrual_on: accrual_on, due_on: due_on, document_type: "boleta" })
    raise "no se pudo crear el gasto: #{result.errors.inspect}" unless result.ok?

    result.record.obligation
  end

  def pay(amount, supplier: @supplier, allocations: nil, paid_on: Date.current, method: "bank_transfer", token: nil, reference: nil, user: @admin, obligations: nil)
    obligations ||= supplier ? Finance::Distribution.pending_obligations(supplier).to_a : []
    allocations ||= Finance::Distribution.suggest(obligations, pesos(amount)).allocations
    Finance::RegisterPayment.call(supplier: supplier, user: user, amount_cents: pesos(amount), paid_on: paid_on, payment_method: method, allocations: allocations, reference: reference, request_token: token)
  end

  def balances(*obligations)
    obligations.map { |o| Obligation.find(o.id).balance_cents }
  end

  # Huella de todo lo que el módulo NO debe tocar en la etapa 1.
  def untouchable_snapshot
    [
      StockItem.order(:id).pluck(:id, :quantity, :minimum_quantity, :active), StockMovement.count,
      RawMaterial.order(:id).pluck(:id, :purchase_price_cents, :purchase_quantity, :unit_cost_cents, :supplier, :active), RawMaterialCostChange.count,
      RecipeComponent.order(:id).pluck(:id, :quantity, :unit), ProductRecipe.count,
      Product.order(:id).pluck(:id, :cost_cents, :price_cents), Preparation.order(:id).pluck(:id, :yield_quantity)
    ]
  end
end
