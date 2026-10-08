module CustomerAccounts
  Result = Struct.new(:customer_payment, :payments, :credit_cents, :errors, :duplicate, keyword_init: true) do
    def ok?
      errors.blank?
    end

    def duplicate?
      duplicate == true
    end
  end
end
