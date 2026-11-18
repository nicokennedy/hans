require "zip"
require "nokogiri"

module Customers
  # Lector mínimo de .xlsx (HANS solo tiene gem para escribir Excel): devuelve las filas de
  # una hoja como arrays de texto, respetando las columnas vacías. Lee cadenas compartidas,
  # texto en línea y números. Es para la importación de direcciones por consola.
  class XlsxRows
    class Error < StandardError; end

    NS = { "x" => "http://schemas.openxmlformats.org/spreadsheetml/2006/main" }.freeze
    REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships".freeze

    def initialize(data)
      @parts = {}
      Zip::File.open_buffer(StringIO.new(data)) do |zip|
        zip.each { |entry| @parts[entry.name] = entry.get_input_stream.read if entry.file? && entry.name.end_with?(".xml", ".rels") }
      end
    rescue Zip::Error => e
      raise Error, "El archivo no es un Excel .xlsx válido (#{e.message})."
    end

    def sheet_names
      workbook.xpath("//x:sheets/x:sheet", NS).map { |sheet| sheet["name"] }
    end

    # Filas de la hoja `name` (o de la primera si no existe), como arrays de String.
    def rows(name)
      doc = Nokogiri::XML(@parts.fetch(sheet_path(name)) { raise Error, "No se encontró la hoja #{name}." })
      doc.xpath("//x:sheetData/x:row", NS).map do |row|
        cells = []
        row.xpath("x:c", NS).each do |cell|
          cells[column_index(cell["r"]) || cells.size] = cell_value(cell)
        end
        cells.map(&:to_s)
      end
    end

    private

    def workbook
      @workbook ||= Nokogiri::XML(@parts.fetch("xl/workbook.xml") { raise Error, "El archivo no es un Excel .xlsx válido." })
    end

    def sheet_path(name)
      sheets = workbook.xpath("//x:sheets/x:sheet", NS)
      sheet = sheets.find { |s| s["name"] == name } || sheets.first
      raise Error, "El Excel no tiene hojas." unless sheet

      rel_id = sheet.attribute_with_ns("id", REL_NS)&.value
      rels = Nokogiri::XML(@parts.fetch("xl/_rels/workbook.xml.rels", ""))
      target = rels.remove_namespaces!.xpath("//Relationship[@Id='#{rel_id}']").first&.[]("Target")
      raise Error, "No se pudo leer la hoja #{name}." unless target

      target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
    end

    def shared_strings
      @shared_strings ||= begin
        doc = Nokogiri::XML(@parts.fetch("xl/sharedStrings.xml", "<sst/>"))
        doc.xpath("//x:si", NS).map { |si| si.xpath(".//x:t", NS).map(&:text).join }
      end
    end

    def cell_value(cell)
      case cell["t"]
      when "s" then shared_strings[cell.at_xpath("x:v", NS)&.text.to_i]
      when "inlineStr" then cell.xpath(".//x:is//x:t", NS).map(&:text).join
      else
        raw = cell.at_xpath("x:v", NS)&.text.to_s
        raw.match?(/\A-?\d+\.0+\z/) ? raw.sub(/\.0+\z/, "") : raw
      end
    end

    def column_index(ref)
      letters = ref.to_s[/\A[A-Z]+/]
      return nil unless letters

      letters.each_char.reduce(0) { |sum, char| sum * 26 + (char.ord - 64) } - 1
    end
  end
end
