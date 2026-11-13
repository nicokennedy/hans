require "csv"

module RetailCatalog
  # Importa el catálogo exportado de TakePedido (CSV) a la tienda minorista, agrupando los tamaños de un
  # mismo producto como variantes: "Torta nuez 18 cm" y "Torta nuez 22 cm" pasan a ser UN producto
  # "Torta nuez" con dos variantes, cada una con su precio y su disponibilidad.
  #
  # Seguro y repetible:
  #  - dry_run (por defecto): hace todo dentro de una transacción y la deshace al final; solo reporta.
  #  - Cada fila del CSV queda ligada a su variante por external_ref ("takepedido:<id>"): una segunda
  #    corrida encuentra lo ya importado y no duplica productos ni variantes.
  #  - Productos que ya existían en HANS (mismo nombre normalizado o una variante ya importada): no se
  #    modifican salvo update_existing: true, y siempre se informan las diferencias. Fotos, código,
  #    nombre, destacado y orden de un producto existente no se tocan nunca.
  #  - No borra productos ni variantes y no toca pedidos, productos mayoristas ni stock de producción.
  #  - Filas no disponibles en TakePedido -> variante deshabilitada; producto sin variantes habilitadas
  #    -> oculto. Productos de temporada -> ocultos y marcados para revisión.
  class TakepedidoImport
    REF_PREFIX = "takepedido:"
    TORTA_CATEGORIES = ["Tortas grandes", "Tortas medianas", "Mini Tortas"].freeze
    # Categoría de destino por categoría de TakePedido (las tortas de todos los tamaños van juntas).
    CATEGORY_MAP = { "Tortas grandes" => "Tortas", "Tortas medianas" => "Tortas", "Mini Tortas" => "Tortas",
                     "Cajitas" => "Cajitas", "Vasitos" => "Vasitos", "Box Desayuno" => "Box Desayuno" }.freeze
    CATEGORY_ORDER = ["Tortas", "Cajitas", "Vasitos", "Box Desayuno"].freeze
    # Productos de TakePedido con nombres distintos que se unifican como variantes de uno solo (aprobado
    # por HANS). Cada variante conserva su propia descripción (condiciones de sabores de cada box).
    # [categoría de destino, clave normalizada del nombre] => [nombre del producto, nombre de la variante, orden]
    MERGES = {
      ["Vasitos", "box 12"] => ["Box de vasitos", "Box x 12", 12],
      ["Vasitos", "box 30 vasito"] => ["Box de vasitos", "Box x 30", 30]
    }.freeze
    SEASONAL = /\bmama\b|halloween|dia del nin|navidad|pascua|san valentin|reyes/i # sobre el texto sin tildes
    STOPWORDS = %w[y con de la el los las].freeze
    NAME_FIXES = { /\bcheescake\b/i => "Cheesecake" }.freeze
    SIZE_CM = /(\d{1,2})\s*cm\b/i
    # Presentación de cajitas: solo si la descripción EMPIEZA con "Caja(ita) (de) N unidades/macarons/alfajores".
    UNITS = /\A\s*caj(?:a|ita)\s+(?:de\s+)?(\d{1,3})\s+(?:unidades|macarons|alfajores)\b\.?\s*/i

    Row = Struct.new(:ref, :source_category, :order, :raw_name, :name, :description, :price_cents, :sale_cents, :available,
                     :stock_managed, :stock_quantity, :size, :size_value, :size_kind, :size_hint, keyword_init: true)
    Group = Struct.new(:key, :name, :category, :description, :rows, :seasonal, :notes, :variant_descriptions, keyword_init: true)
    Action = Struct.new(:group, :kind, :product, :details, keyword_init: true) # kind: :create, :update, :unchanged, :needs_update

    attr_reader :rows, :groups, :actions, :warnings

    def self.read(path)
      new(CSV.read(path, headers: true, encoding: "bom|utf-8").map(&:to_h))
    end

    def initialize(records)
      @records = records
      @warnings = []
      @rows = records.map { |record| build_row(record) }
      @groups = build_groups
    end

    # dry_run: true -> se deshace todo. update_existing: true -> aplica las diferencias a productos ya
    # existentes (precio y disponibilidad de sus variantes, variantes nuevas, descripción vacía).
    def call(dry_run: true, update_existing: false)
      @actions = []
      # requires_new: aunque se llame dentro de otra transacción, la simulación se deshace de verdad.
      ActiveRecord::Base.transaction(requires_new: true) do
        categories = ensure_categories
        @groups.each_with_index { |group, index| @actions << import_group(group, categories.fetch(group.category), index, update_existing) }
        @summary = summarize
        raise ActiveRecord::Rollback if dry_run
      end
      self
    end

    def summary
      @summary || summarize
    end

    def self.normalize_key(name)
      I18n.transliterate(name.to_s).downcase.gsub(/[^a-z0-9 ]/, " ").split
          .reject { |w| STOPWORDS.include?(w) }
          .map { |w| w.length > 3 && w.end_with?("s") ? w.chomp("s") : w }
          .map { |w| w == "cheescake" ? "cheesecake" : w }
          .join(" ")
    end

    private

    # --- Normalización ---------------------------------------------------------------------------------

    def build_row(record)
      raw_name = record["nombre"].to_s.squish
      name = NAME_FIXES.reduce(raw_name.sub(/\s*\.\s*/, ". ").sub(/\.\s*\z/, "")) { |text, (pattern, fix)| text.gsub(pattern, fix) }
      description = record["descripcion"].to_s.gsub("⁠", "").gsub(/\r\n?/, "\n").strip
      size_kind, size_value = detect_size(record["categoria"].to_s, description)
      Row.new(
        ref: record["id"].to_s.strip, source_category: record["categoria"].to_s.strip, order: record["orden_en_categoria"].to_i,
        raw_name: raw_name, name: name, description: description,
        price_cents: Integer(record["precio"].to_s.strip, exception: false).to_i * 100,
        sale_cents: Integer(record["precio_rebaja"].to_s.strip, exception: false).to_i * 100,
        available: record["disponible"] == "true" && record["stock"] == "true",
        stock_managed: record["manejo_de_stock"] == "true",
        stock_quantity: Integer(record["cantidad_stock"].to_s.strip, exception: false),
        size: size_label(size_kind, size_value), size_value: size_value, size_kind: size_kind
      )
    end

    def detect_size(category, description)
      if TORTA_CATEGORIES.include?(category) && (match = description.match(SIZE_CM))
        [:cm, match[1].to_i]
      elsif category == "Cajitas" && (match = description.match(UNITS))
        [:units, match[1].to_i]
      else
        [nil, nil]
      end
    end

    def size_label(kind, value)
      case kind
      when :cm then "#{value} cm"
      when :units then "Caja x #{value}"
      end
    end

    def build_groups
      grouped = @rows.group_by do |row|
        category = CATEGORY_MAP.fetch(row.source_category, row.source_category)
        key = self.class.normalize_key(row.name)
        if (merge = MERGES[[category, key]])
          row.name, row.size, row.size_value = merge
          row.size_kind = :merged
          key = self.class.normalize_key(merge.first)
        end
        [category, key]
      end
      grouped.map do |(category, key), rows|
        if rows.first.size_kind == :merged
          rows = rows.sort_by(&:size_value)
          notes = ["Unificado: #{rows.map(&:raw_name).join(' + ')} → “#{rows.first.name}”; cada variante conserva su descripción."]
          next Group.new(key: key, name: rows.first.name, category: category, description: nil, rows: rows, seasonal: false, notes: notes, variant_descriptions: true)
        end

        rows = rows.sort_by { |r| [r.size_value || 0, r.ref] }
        # Un producto de una sola fila no tiene variantes: su "tamaño" queda en la descripción.
        if rows.size == 1
          rows.first.size_hint = rows.first.size
          rows.first.size = nil
        end
        notes = []
        names = rows.map(&:name).uniq
        name = names.max_by { |n| [rows.count { |r| r.name == n }, rows.rindex { |r| r.name == n }] }
        notes << "Nombres unificados: #{names.join(' / ')} → “#{name}”." if names.size > 1
        notes << "Nombre corregido: “#{rows.last.raw_name}” → “#{name}”." if names.size == 1 && rows.last.raw_name != name && rows.last.raw_name.downcase.include?("cheescake")
        sizes = rows.map(&:size)
        notes << "Un solo tamaño en TakePedido (#{rows.first.size_hint}): queda como producto simple; el tamaño sigue en la descripción." if rows.size == 1 && rows.first.size_hint
        if rows.size > 1 && (sizes.any?(&:nil?) || sizes.uniq.size != sizes.size)
          notes << "CONFLICTO: hay filas sin tamaño o con el tamaño repetido (#{sizes.map { |s| s || 'sin tamaño' }.join(', ')})."
        end
        rows.each do |r|
          expected = { "Tortas grandes" => [22], "Tortas medianas" => [18], "Mini Tortas" => [10] }[r.source_category]
          notes << "Tamaño ambiguo: #{r.size} figura en “#{r.source_category}”." if expected && r.size_value && !expected.include?(r.size_value)
        end
        notes << "Precio de rebaja en TakePedido ignorado (#{rows.select { |r| r.sale_cents.positive? }.map(&:ref).join(', ')})." if rows.any? { |r| r.sale_cents.positive? }
        seasonal = rows.any? { |r| I18n.transliterate("#{r.name} #{r.description}").match?(SEASONAL) }
        notes << "De temporada: se importa oculto para revisar." if seasonal
        description, description_note = merged_description(rows)
        notes << description_note if description_note
        notes << "Sin descripción comercial." if description.blank?
        notes << "La descripción menciona un adicional (“Opcional frutillas $5000”) que no se modela como variante." if description.to_s.match?(/opcional/i)
        Group.new(key: key, name: name, category: category, description: description, rows: rows, seasonal: seasonal, notes: notes, variant_descriptions: false)
      end.sort_by { |g| [CATEGORY_ORDER.index(g.category) || 99, g.rows.map(&:order).min, g.name.downcase] }
    end

    # La descripción sin la referencia al tamaño (que pasa a ser la variante). Se usa la más completa;
    # si los tamaños tenían textos distintos, se avisa.
    def merged_description(rows)
      cleaned = rows.map { |r| [r, clean_description(r)] }
      texts = cleaned.map(&:last).reject(&:blank?)
      return [nil, nil] if texts.empty?

      chosen = cleaned.reject { |_, text| text.blank? }.max_by { |r, text| [text.length, r.size_value || 0] }
      note = texts.uniq.size > 1 ? "Descripciones distintas entre tamaños: se usó la de #{chosen.first.size || 'la fila'} (#{chosen.first.ref})." : nil
      [chosen.last, note]
    end

    def clean_description(row)
      text = row.description.dup
      return text.strip.presence if row.size.nil? # sin variantes: la descripción queda como está

      if row.size_kind == :cm
        text = text.gsub(/\s*,?\s*de\s+\d{1,2}\s*cm\s*\.?/i, ".").gsub(/\A\s*\d{1,2}\s*cm\s*\.?\s*\z/i, "")
      elsif row.size_kind == :units
        text = text.sub(UNITS, "")
      end
      text.gsub(/\.\s*\./, ".").gsub(/\s+\./, ".").gsub(/[ \t]+\n/, "\n").strip.presence
    end

    # --- Escritura ---------------------------------------------------------------------------------

    def ensure_categories
      @created_categories = []
      @groups.map(&:category).uniq.to_h do |name|
        category = RetailCategory.where("lower(name) = ?", name.downcase).first
        unless category
          category = RetailCategory.create!(name: name, active: true, position: (RetailCategory.maximum(:position) || 0) + 1)
          @created_categories << name
        end
        [name, category]
      end
    end

    def import_group(group, category, index, update_existing)
      product = existing_product_for(group)
      return create_product(group, category, index) unless product

      changes, info = differences(group, product)
      return Action.new(group: group, kind: :unchanged, product: product, details: info) if changes.empty?
      return Action.new(group: group, kind: :needs_update, product: product, details: changes + info) unless update_existing

      apply_update(group, product)
      Action.new(group: group, kind: :update, product: product, details: changes + info)
    end

    def existing_product_for(group)
      refs = group.rows.map { |r| REF_PREFIX + r.ref }
      RetailProductVariant.where(external_ref: refs).first&.retail_product ||
        RetailProduct.includes(:variants).find { |p| self.class.normalize_key(p.name) == group.key }
    end

    def create_product(group, category, index)
      product = RetailProduct.new(
        name: group.name, description: group.description, retail_category: category,
        active: !group.seasonal && group.rows.any?(&:available), featured: false,
        position: (RetailProduct.maximum(:position) || 0) + 1
      )
      group.rows.each_with_index { |row, i| product.variants.build(variant_attributes(row, i, group)) }
      product.save!
      Action.new(group: group, kind: :create, product: product, details: [])
    end

    def variant_attributes(row, index, group)
      { name: group.rows.size > 1 ? row.size : nil, description: (group.variant_descriptions ? row.description : nil), position: index + 1, price_cents: row.price_cents,
        active: row.available, stock_quantity: (row.stock_managed ? [row.stock_quantity.to_i, 0].max : nil), external_ref: REF_PREFIX + row.ref }
    end

    # Diferencias entre el CSV y un producto que ya está en HANS (sin aplicar nada): [cambios que se
    # aplicarían con update_existing, datos que difieren pero se conservan siempre].
    def differences(group, product)
      details = []
      info = []
      info << "Nombre en HANS “#{product.name}” (CSV: “#{group.name}”): se conserva el de HANS." if product.name != group.name
      details << "Descripción vacía en HANS: se completaría con la del CSV." if product.description.blank? && group.description.present?
      info << "Descripción distinta a la del CSV: se conserva la de HANS." if product.description.present? && group.description.present? && product.description != group.description
      info << "Categoría en HANS “#{product.retail_category.name}” (CSV: “#{group.category}”): se conserva." if product.retail_category.name.downcase != group.category.downcase

      by_ref = product.variants.index_by(&:external_ref)
      legacy = product.variants.select { |v| v.external_ref.nil? }
      group.rows.each_with_index do |row, i|
        variant = by_ref[REF_PREFIX + row.ref]
        label = row.size || "única"
        if variant
          details << "#{label}: precio #{money(variant.price_cents)} → #{money(row.price_cents)}." if variant.price_cents != row.price_cents
          details << "#{label}: disponibilidad #{variant.active? ? 'habilitada' : 'deshabilitada'} → #{row.available ? 'habilitada' : 'deshabilitada'}." if variant.active? != row.available
        elsif i == group.rows.size - 1 && legacy.size == 1
          details << "#{label}: la variante actual de HANS (#{legacy.first.name || 'sin nombre'}, #{money(legacy.first.price_cents)}) pasaría a ser “#{label}” a #{money(row.price_cents)}."
        else
          details << "#{label}: variante nueva a #{money(row.price_cents)}#{row.available ? '' : ' (deshabilitada)'}."
        end
      end
      [details, info]
    end

    def apply_update(group, product)
      product.description = group.description if product.description.blank? && group.description.present?
      by_ref = product.variants.index_by(&:external_ref)
      legacy = product.variants.select { |v| v.external_ref.nil? }
      group.rows.each_with_index do |row, i|
        attrs = variant_attributes(row, i, group)
        variant = by_ref[attrs[:external_ref]]
        if variant
          variant.assign_attributes(price_cents: row.price_cents, active: row.available)
        elsif i == group.rows.size - 1 && legacy.size == 1
          legacy.first.assign_attributes(attrs.except(:stock_quantity)) # la variante existente pasa a ser el tamaño más grande
        else
          product.variants.build(attrs)
        end
      end
      product.save!
    end

    def summarize
      variants = @groups.sum { |g| g.rows.size }
      by_kind = (@actions || []).group_by(&:kind)
      {
        records: @rows.size, products: @groups.size, variants: variants,
        created: by_kind.fetch(:create, []).size, updated: by_kind.fetch(:update, []).size,
        needs_update: by_kind.fetch(:needs_update, []).size, unchanged: by_kind.fetch(:unchanged, []).size,
        hidden_products: @groups.count { |g| g.seasonal || g.rows.none?(&:available) },
        disabled_variants: @rows.count { |r| !r.available }, seasonal: @groups.count(&:seasonal),
        missing_descriptions: @groups.count { |g| g.description.blank? && !g.variant_descriptions }, categories_created: @created_categories || []
      }
    end

    def money(cents)
      "$#{Retail::Money.format_pesos(cents)}"
    end
  end
end
