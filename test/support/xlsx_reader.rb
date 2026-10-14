require "zip"
require "nokogiri"

# Lector mínimo de .xlsx para los tests (no hay gem de lectura en el proyecto): abre el zip,
# resuelve cadenas y devuelve cada hoja como filas de celdas con valor, tipo y formato.
class XlsxReader
  Cell = Struct.new(:value, :type, :format)
  EXCEL_EPOCH = Date.new(1899, 12, 30)

  attr_reader :sheets, :parts

  def initialize(data)
    @parts = {}
    Zip::InputStream.open(StringIO.new(data)) do |zip|
      while (entry = zip.get_next_entry)
        @parts[entry.name] = zip.read
      end
    end
    @shared = shared_strings
    @formats = number_formats
    @sheets = workbook_sheets
  end

  def sheet_names
    @sheets.keys
  end

  # Matriz de valores crudos (texto, números, fechas ya convertidas).
  def rows(name)
    @sheets.fetch(name)[:rows].map { |row| row.map(&:value) }
  end

  def cells(name)
    @sheets.fetch(name)[:rows]
  end

  def xml(name)
    @sheets.fetch(name)[:xml]
  end

  private

  def doc(path)
    # strict: un XML mal formado (que Excel rechazaría) hace fallar el test.
    Nokogiri::XML(@parts.fetch(path)) { |config| config.strict }.tap(&:remove_namespaces!)
  end

  def shared_strings
    return [] unless @parts["xl/sharedStrings.xml"]

    doc("xl/sharedStrings.xml").xpath("//si").map { |si| si.xpath(".//t").map(&:text).join }
  end

  # índice de estilo (cellXfs) -> código de formato
  def number_formats
    styles = doc("xl/styles.xml")
    custom = styles.xpath("//numFmts/numFmt").to_h { |n| [n["numFmtId"].to_i, n["formatCode"]] }
    styles.xpath("//cellXfs/xf").map { |xf| id = xf["numFmtId"].to_i; custom[id] || id }
  end

  def workbook_sheets
    wb = doc("xl/workbook.xml")
    rels = doc("xl/_rels/workbook.xml.rels").xpath("//Relationship").to_h { |r| [r["Id"], r["Target"]] }
    wb.xpath("//sheets/sheet").each_with_object({}) do |sheet, result|
      rid = sheet.attribute_with_ns("id", "http://schemas.openxmlformats.org/officeDocument/2006/relationships")&.value || sheet["id"]
      path = "xl/#{rels.fetch(rid)}".sub("xl//", "xl/")
      sheet_doc = doc(path)
      result[sheet["name"]] = { xml: sheet_doc, rows: sheet_doc.xpath("//sheetData/row").map { |row| row.xpath("c").map { |c| parse_cell(c) } } }
    end
  end

  def parse_cell(c)
    type = c["t"]
    format = @formats[c["s"].to_i]
    value = case type
            when "s" then @shared[c.at_xpath("v").text.to_i]
            when "inlineStr" then c.xpath(".//t").map(&:text).join
            when "str" then c.at_xpath("v")&.text
            when "b" then c.at_xpath("v").text == "1"
            else
              raw = c.at_xpath("v")&.text
              raw.nil? ? nil : (raw.include?(".") || raw.match?(/e/i) ? raw.to_f : raw.to_i)
            end
    value = EXCEL_EPOCH + value if format == "dd/mm/yyyy" && value.is_a?(Numeric)
    Cell.new(value, type, format)
  end
end
