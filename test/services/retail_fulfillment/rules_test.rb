require "test_helper"

# Etapa 3: calendario de retiro y envío minorista (días, franjas, anticipación en días calendario
# de Argentina, fechas sin servicio) y cálculo de envío/total en el servidor.
class RetailFulfillment::RulesTest < ActiveSupport::TestCase
  # Semana de referencia (noviembre 2026): lunes 9, martes 10, miércoles 11, ... sábado 14, domingo 15.
  MON = Date.new(2026, 11, 9)
  TUE = MON + 1
  WED = MON + 2
  FRI = MON + 4
  SAT = MON + 5
  SUN = MON + 6
  NEXT_MON = MON + 7

  def ar(date, hour, min = 0)
    ActiveSupport::TimeZone["America/Argentina/Buenos_Aires"].local(date.year, date.month, date.day, hour, min)
  end

  def calendar(now)
    RetailFulfillment::Calendar.new(now: now)
  end

  def zone(name)
    RetailFulfillmentSetting.current
    RetailDeliveryZone.find_by!(name: name)
  end

  def quote(**args)
    RetailFulfillment::Quote.call(now: ar(MON, 10), **args)
  end

  # --- Configuración inicial ---

  test "la configuración inicial coincide con el ticket" do
    setting = RetailFulfillmentSetting.current
    assert_equal 2, setting.min_lead_days
    assert_nil setting.pickup_point_details, "la dirección del punto de retiro no se inventa"

    labels = ->(service) { RetailServiceWindow.for_service(service).order(:wday).map(&:label) }
    assert_equal [nil] + ["14:00 a 17:00 hs"] * 5 + ["11:00 a 13:00 hs"], labels.call("pickup")
    assert_equal [nil] + ["8:30 a 13:00 hs"] * 6, labels.call("delivery")

    zones = RetailDeliveryZone.ordered.map { |z| [z.name, z.coverage, z.price_cents, z.active?] }
    assert_equal [
      ["Zona 1", "Costa, Independencia, Colón, Vértiz", 500_000, true],
      ["Zona 2", "Centro, zona Facultad", 600_000, true],
      ["Zona 3", "Constitución, barrios privados, Champagnat hasta Allio", 700_000, true]
    ], zones
    assert_equal "Retiro por zona Plaza del Agua", RetailFulfillment.service_name("pickup")
    assert_equal "Envío a domicilio", RetailFulfillment.service_name("delivery")
  end

  test "instalar la configuración inicial es idempotente y no recrea zonas borradas" do
    RetailFulfillmentSetting.current
    RetailDeliveryZone.find_by!(name: "Zona 3").destroy!
    assert_no_difference ["RetailFulfillmentSetting.count", "RetailServiceWindow.count", "RetailDeliveryZone.count"] do
      RetailFulfillment::Defaults.install!
    end
  end

  # --- Días y franjas ---

  test "retiro: lunes a viernes 14 a 17, sábado 11 a 13, domingo no" do
    c = calendar(ar(MON - 7, 9))
    (MON..FRI).each do |day|
      assert c.available?("pickup", day), day.to_s
      assert_equal "14:00 a 17:00 hs", c.window_label("pickup", day)
    end
    assert c.available?("pickup", SAT)
    assert_equal "11:00 a 13:00 hs", c.window_label("pickup", SAT)
    assert_not c.available?("pickup", SUN)
    assert_equal "Los domingos no hay retiro por zona Plaza del Agua.", c.unavailable_reason("pickup", SUN)
  end

  test "envío: lunes a sábado 8:30 a 13 (franja), domingo no" do
    c = calendar(ar(MON - 7, 9))
    (MON..SAT).each do |day|
      assert c.available?("delivery", day), day.to_s
      assert_equal "8:30 a 13:00 hs", c.window_label("delivery", day)
    end
    assert_not c.available?("delivery", SUN)
    assert_equal "Los domingos no hay envío a domicilio.", c.unavailable_reason("delivery", SUN)
  end

  test "los días y horarios salen de la configuración, no del código" do
    RetailFulfillmentSetting.current
    RetailServiceWindow.find_by!(service: "pickup", wday: 0).update!(enabled: true, opens_minute: 600, closes_minute: 720)
    RetailServiceWindow.find_by!(service: "delivery", wday: 6).update!(enabled: false)

    c = calendar(ar(MON - 7, 9))
    assert c.available?("pickup", SUN)
    assert_equal "10:00 a 12:00 hs", c.window_label("pickup", SUN)
    assert_not c.available?("delivery", SAT)
  end

  # --- Anticipación: dos días calendario en Argentina ---

  test "compra lunes 10:00 o 23:30: primera entrega el miércoles" do
    [ar(MON, 10), ar(MON, 23, 30), ar(MON, 0, 0)].each do |now|
      c = calendar(now)
      assert_equal WED, c.earliest_date
      assert_equal WED, c.first_available_date("pickup")
      assert_equal WED, c.first_available_date("delivery")
      assert_not c.available?("pickup", TUE)
    end
    assert_equal "Los pedidos necesitan al menos 2 días de anticipación: la primera fecha disponible es el miércoles 11/11.",
      calendar(ar(MON, 23, 30)).unavailable_reason("delivery", TUE)
  end

  test "compra viernes o sábado: primera entrega el lunes (el domingo no está habilitado)" do
    [ar(FRI, 9), ar(FRI, 23, 59), ar(SAT, 8), ar(SAT, 23, 30)].each do |now|
      c = calendar(now)
      assert_equal NEXT_MON, c.first_available_date("pickup"), now.to_s
      assert_equal NEXT_MON, c.first_available_date("delivery"), now.to_s
    end
    # Viernes: el domingo sería la fecha mínima, pero está cerrado.
    assert_equal SUN, calendar(ar(FRI, 9)).earliest_date
  end

  test "cuenta la fecha de Argentina aunque el servidor esté en UTC (cerca de medianoche)" do
    # Lunes 23:30 en Argentina = martes 02:30 UTC: sigue siendo lunes para la regla.
    utc = Time.utc(2026, 11, 10, 2, 30)
    assert_equal WED, calendar(utc).earliest_date
    assert_equal WED, calendar(utc.in_time_zone("UTC")).earliest_date
    # Martes 00:05 en Argentina: ya es martes, primera fecha el jueves.
    assert_equal WED + 1, calendar(Time.utc(2026, 11, 10, 3, 5)).earliest_date
  end

  test "la anticipación se configura en días" do
    RetailFulfillmentSetting.current.update!(min_lead_days: 0)
    assert calendar(ar(MON, 10)).available?("pickup", MON)
    RetailFulfillmentSetting.current.update!(min_lead_days: 4)
    assert_equal FRI, calendar(ar(MON, 10)).first_available_date("pickup")
  end

  # --- Fechas sin servicio ---

  test "una fecha bloqueada para retiro sigue disponible para envío, y 'ambas' bloquea las dos" do
    RetailServiceClosure.create!(date: WED, service: "pickup", reason: "Inventario")
    RetailServiceClosure.create!(date: FRI, service: "all")
    c = calendar(ar(MON, 9))

    assert_not c.available?("pickup", WED)
    assert_equal "El miércoles 11/11 no hay retiro por zona Plaza del Agua: Inventario.", c.unavailable_reason("pickup", WED)
    assert c.available?("delivery", WED)
    assert_not c.available?("pickup", FRI)
    assert_not c.available?("delivery", FRI)
    assert_equal "El viernes 13/11 no hay envío a domicilio.", c.unavailable_reason("delivery", FRI)
    assert c.available?("pickup", SAT), "los días habituales no cambian"
    assert_equal WED + 1, c.first_available_date("pickup")
  end

  test "las fechas bloqueadas minoristas y mayoristas son independientes" do
    BlockedDate.create!(date: WED, reason: "Sin reparto mayorista", active: true)
    assert calendar(ar(MON, 9)).available?("pickup", WED), "un bloqueo mayorista no afecta a la tienda"

    thu = WED + 1
    RetailServiceClosure.create!(date: thu, service: "all")
    assert_nil BlockedDate.for_date(thu), "un bloqueo minorista no crea bloqueos mayoristas"
  end

  test "no se aceptan fechas más allá del horizonte" do
    c = calendar(ar(MON, 9))
    assert c.available?("pickup", c.last_date) || c.last_date.sunday?
    assert_match "hasta el", c.unavailable_reason("pickup", c.last_date + 1)
  end

  # --- Costos y total ---

  test "retiro gratis; zonas 1, 2 y 3 a $5.000, $6.000 y $7.000; total = productos + envío" do
    pickup = quote(service: "pickup", date: WED, subtotal_cents: 2_500_000)
    assert pickup.ok?, pickup.errors.inspect
    assert_equal 0, pickup.shipping_cents
    assert_equal 2_500_000, pickup.total_cents
    assert_nil pickup.zone
    assert_nil pickup.address

    { "Zona 1" => 500_000, "Zona 2" => 600_000, "Zona 3" => 700_000 }.each do |name, cents|
      result = quote(service: "delivery", date: WED.iso8601, zone_id: zone(name).id.to_s, address: " Alem 123 ", subtotal_cents: 2_500_000)
      assert result.ok?, result.errors.inspect
      assert_equal cents, result.shipping_cents
      assert_equal 2_500_000 + cents, result.total_cents
      assert_equal name, result.zone_name
      assert_equal "Alem 123", result.address
      assert_equal "8:30 a 13:00 hs", result.window_label
    end
  end

  test "el costo sale de la zona configurada en ese momento" do
    zone("Zona 1").update!(price: "5.500")
    assert_equal 550_000, quote(service: "delivery", date: WED, zone_id: zone("Zona 1").id, address: "X 1").shipping_cents
  end

  # --- Validaciones ---

  test "rechaza fechas inválidas, modalidades inexistentes y fechas anteriores a la anticipación" do
    assert_equal ["La fecha de entrega no es válida."], quote(service: "pickup", date: "2026-02-30").errors
    assert_equal ["La fecha de entrega no es válida."], quote(service: "pickup", date: "mañana").errors
    assert_equal ["Elegí una fecha de entrega."], quote(service: "pickup", date: "").errors
    assert_equal ["Elegí una modalidad de entrega válida."], quote(service: "express", date: WED).errors
    assert_match "anticipación", quote(service: "pickup", date: TUE).errors.first
    assert_match "anticipación", quote(service: "pickup", date: MON - 30).errors.first
    assert_match "domingos", quote(service: "pickup", date: SUN).errors.first
  end

  test "envío: exige zona existente y activa, y dirección" do
    assert_equal ["Elegí la zona de envío.", "Completá la dirección de entrega."], quote(service: "delivery", date: WED).errors
    assert_equal ["La zona de envío elegida no está disponible."], quote(service: "delivery", date: WED, zone_id: "999999999", address: "X").errors
    assert_equal ["La zona de envío elegida no está disponible."], quote(service: "delivery", date: WED, zone_id: "1 OR 1=1", address: "X").errors

    z = zone("Zona 2")
    z.update!(active: false)
    result = quote(service: "delivery", date: WED, zone_id: z.id, address: "X")
    assert_equal ["La zona de envío elegida no está disponible."], result.errors
    assert_equal 0, result.shipping_cents
  end

  test "Options entrega al checkout las fechas, franjas y zonas ya filtradas" do
    RetailServiceClosure.create!(date: WED, service: "delivery")
    zone("Zona 3").update!(active: false)
    options = RetailFulfillment::Options.call(now: ar(MON, 23, 30))

    assert_equal WED.iso8601, options[:earliest_date]
    pickup, delivery = options[:services]
    assert_equal ["pickup", "Retiro por zona Plaza del Agua", "$0 — Gratis"], [pickup[:key], pickup[:name], pickup[:cost]]
    assert_equal({ date: WED.iso8601, label: "14:00 a 17:00 hs" }, pickup[:dates].first)
    assert_equal (WED + 1).iso8601, delivery[:dates].first[:date]
    assert_equal "Franja de entrega", delivery[:window_name]
    assert delivery[:dates].none? { |d| Date.iso8601(d[:date]).sunday? }
    assert_equal ["Zona 1", "Zona 2"], options[:zones].map { |z| z[:name] }
    assert_equal "$5.000", options[:zones].first[:price]
  end
end
