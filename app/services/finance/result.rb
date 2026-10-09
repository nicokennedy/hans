module Finance
  Result = Struct.new(:payment, :applications, :advance_cents, :record, :errors, :duplicate, keyword_init: true) do
    def ok?
      errors.blank?
    end

    def duplicate?
      duplicate == true
    end
  end
end
