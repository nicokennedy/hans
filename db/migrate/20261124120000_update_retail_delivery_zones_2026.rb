# Zonas de envío definitivas de la tienda minorista (rediseño 2026, Etapa 1):
#
#   Zona 1  Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. Independencia            $5.000
#   Zona 2  Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. M. Champagnat - Av. Libertad  $6.000
#   Zona 3  Av. Libertad - Av. M. Champagnat - Av. José Estrada                           $7.000
#   Zona 4  Av. Mario Bravo - Av. Jacinto Peralta Ramos - Av. de los Trabajadores           $6.000
#   Zona 5  Barrios del sur                                                                $7.000
#
# Solo datos, no destructiva e idempotente:
#  - Busca cada zona por nombre ("Zona 1"... sin distinguir mayúsculas). Si existe, actualiza
#    descripción (coverage), precio, orden y la deja habilitada; si no, la crea.
#  - Otras zonas que existan con otro nombre no se modifican, salvo su orden: pasan detrás de las
#    cinco (conservando su orden relativo) para que el checkout muestre primero Zona 1 a Zona 5.
#  - NO toca retail_orders: cada pedido ya guardó su zona, el nombre (delivery_zone_name) y el costo
#    aplicado (shipping_cents), así que los pedidos registrados conservan sus importes.
# Después todo se sigue administrando desde Tienda Minorista → Entregas (sin deploy).
#
# Antes de correrla en producción: verificar las zonas existentes con una consulta de solo lectura
# (ver docs/TIENDA_MINORISTA.md, "Zonas de envío").
class UpdateRetailDeliveryZones2026 < ActiveRecord::Migration[7.1]
  ZONES = [
    ["Zona 1", "Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. Independencia", 500_000],
    ["Zona 2", "Av. Patricio Peralta Ramos - Av. Juan B. Justo - Av. M. Champagnat - Av. Libertad", 600_000],
    ["Zona 3", "Av. Libertad - Av. M. Champagnat - Av. José Estrada", 700_000],
    ["Zona 4", "Av. Mario Bravo - Av. Jacinto Peralta Ramos - Av. de los Trabajadores", 600_000],
    ["Zona 5", "Barrios del sur", 700_000]
  ].freeze

  def up
    names = ZONES.map { |name, _, _| quote(name.downcase) }.join(", ")

    # Las demás zonas (si las hay) van detrás de las cinco, en el mismo orden relativo.
    execute(<<~SQL.squish)
      UPDATE retail_delivery_zones AS z
         SET position = #{ZONES.size} + ranked.rank, updated_at = NOW()
        FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY position, lower(name), id) AS rank
                FROM retail_delivery_zones WHERE lower(name) NOT IN (#{names})) AS ranked
       WHERE z.id = ranked.id
    SQL

    ZONES.each_with_index do |(name, coverage, price_cents), index|
      execute(<<~SQL.squish)
        INSERT INTO retail_delivery_zones (name, coverage, price_cents, active, position, created_at, updated_at)
        VALUES (#{quote(name)}, #{quote(coverage)}, #{price_cents}, TRUE, #{index + 1}, NOW(), NOW())
        ON CONFLICT (lower((name)::text))
        DO UPDATE SET coverage = EXCLUDED.coverage, price_cents = EXCLUDED.price_cents, active = TRUE,
                      position = EXCLUDED.position, updated_at = NOW()
      SQL
    end
  end

  # Revertir no borra ni restaura zonas: los datos quedan como están y se siguen editando desde el
  # administrador (borrar zonas podría dejar pedidos sin su zona).
  def down; end

  private

  def quote(value)
    connection.quote(value)
  end
end
