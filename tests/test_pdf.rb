# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'json'

class TestPdf < Minitest::Test
  include TestParams
  Doc = CabinetCraft::Exporters::PdfDocument
  Reports = CabinetCraft::Exporters::PdfReports
  T0 = Time.utc(2026, 10, 2, 9, 30, 0)

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    CabinetCraft::MachiningConfig.current = CabinetCraft::MachiningConfig.new
  end

  def cabs
    @cabs ||= [CabinetCraft::Cabinet.build(type: 'base_cabinet', label: 'B01', params: params('width' => 800, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 2, 'shelf_count' => 1, 'handle_type' => 'handle_bar')),
     CabinetCraft::Cabinet.build(type: 'base_cabinet', label: 'B02', params: params('door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0, 'height' => 820, 'toe_kick_height' => 100))
              .with_overrides('side_left' => { 'length' => 700.0 })]
  end

  def nest_for(cabinets)
    rows = CabinetCraft::Manufacturing::PartsList.build(cabinets)
    mats = rows.group_by { |r| r['material'] }.map do |label, mrows|
      mat = CabinetCraft::Material.find(mrows.first['material_id'])
      sheet = { 'material' => label, 'grain_free' => mat.nil? || mat.grain == :none, 'grain_axis' => 'length',
                'sheet_length' => (mat ? mat.sheet_length : 2440).to_f, 'sheet_width' => (mat ? mat.sheet_width : 1220).to_f }
      parts = mrows.map { |r| { 'uid' => r['part_uid'], 'part_id' => r['part_id'], 'name' => r['name'], 'length' => r['length'], 'width' => r['width'], 'grain' => r['grain'], 'cabinet_label' => r['cabinet_label'] } }
      CabinetCraft::Manufacturing::Nesting.nest(parts, sheet, CabinetCraft::Manufacturing::Nesting::DEFAULTS)
    end
    total = mats.sum { |m| m['total_area'] }
    used = mats.sum { |m| m['used_area'] }
    { 'materials' => mats, 'totals' => { 'total_sheets' => mats.sum { |m| m['total_sheets'] }, 'total_area' => total, 'used_area' => used, 'waste_area' => total - used,
                                         'utilization' => (used * 100.0 / total).round(2), 'unplaced' => 0 } }
  end

  # Independent structural validation of the file we wrote: xref offsets, stream lengths, page tree.
  def assert_valid_pdf(pdf)
    assert pdf.start_with?("%PDF-1.4\n".b)
    assert pdf.end_with?("%%EOF\n".b)
    xref_pos = pdf[/startxref\n(\d+)\n%%EOF\n\z/n, 1].to_i
    assert pdf.byteslice(xref_pos, 4) == 'xref'.b
    count = pdf.byteslice(xref_pos, 40)[/xref\n0 (\d+)/n, 1].to_i
    entries = pdf.byteslice(xref_pos, pdf.bytesize - xref_pos).scan(/^(\d{10}) 00000 n $/n).flatten.map(&:to_i)
    assert_equal count - 1, entries.size
    entries.each_with_index do |off, i|
      assert_equal "#{i + 1} 0 obj".b, pdf.byteslice(off, "#{i + 1} 0 obj".bytesize), "object #{i + 1} offset"
    end
    pdf.scan(/<< \/Length (\d+) >>\nstream\n/n) do
      start = Regexp.last_match.end(0)
      len = Regexp.last_match(1).to_i
      assert_equal "\nendstream".b, pdf.byteslice(start + len, 10), 'stream length matches'
    end
    pages = pdf.scan(/\/Type \/Page /n).size
    assert_equal pages, pdf[/\/Count (\d+)/n, 1].to_i
    pages
  end

  # --- writer ------------------------------------------------------------------------------------------------
  def test_minimal_document_is_structurally_valid
    d = Doc.new(title: 'T', created: T0)
    d.add_page.text(10, 10, 'Hello (world) \\ test')
    assert_equal 1, assert_valid_pdf(d.render)
    assert_raises(RuntimeError) { Doc.new(title: 'x').render }
  end

  def test_text_encoding_escapes_and_replaces
    assert_equal 'a\\(b\\)c\\\\d'.b, Doc.encode('a(b)c\\d')
    assert_equal "\xD8".b, Doc.encode('Ø') # Windows-1252 byte for O-slash
    assert_equal '?', Doc.encode('木')
    assert_equal 'a b', Doc.encode("a\nb")
  end

  def test_text_metrics
    assert_in_delta 0.556 * 10 / 2.8346, Doc.text_width_mm('0', 10), 0.01 # a digit is 556/1000 em
    assert_operator Doc.text_width_mm('WWWW', 8, :bold), :>, Doc.text_width_mm('iiii', 8, :bold)
    assert_equal Doc.text_width_mm('abc', 8, :mono), Doc.text_width_mm('xyz', 8, :mono)
    short = Doc.fit('B01-DRAWER_3_SIDE_RIGHT', 8, :regular, 20)
    assert short.end_with?('...')
    assert_operator Doc.text_width_mm(short, 8), :<=, 20
    assert_equal 'ok', Doc.fit('ok', 8, :regular, 20)
  end

  def test_report_paginates_with_header_and_footer
    r = CabinetCraft::Exporters::PdfReport.new(title: 'Big', project: 'P', created: T0)
    r.table([{ 'title' => 'A', 'width' => 1, 'align' => :left }], Array.new(200) { |i| ["row #{i}"] })
    pdf = r.render
    pages = assert_valid_pdf(pdf)
    assert_operator pages, :>=, 4
    assert_equal pages, pdf.scan(/Page \d+ of #{pages}/n).size, 'every page carries its own "Page x of y" footer'
  end

  # --- documents ---------------------------------------------------------------------------------------------------
  def documents
    cs = cabs
    rows = CabinetCraft::Manufacturing::PartsList.build(cs)
    list = CabinetCraft::Manufacturing::CuttingList.build(cs)
    labels = CabinetCraft::Manufacturing::Labels.build(cs, project_name: 'VALENTINA KITCHEN', qr: false)
    {
      'parts' => Reports.parts_list(rows, project: 'VALENTINA KITCHEN', created: T0),
      'cutting' => Reports.cutting_list(list, project: 'VALENTINA KITCHEN', created: T0),
      'labels' => Reports.labels(labels, project: 'VALENTINA KITCHEN', created: T0),
      'nesting' => Reports.nesting(nest_for(cs), project: 'VALENTINA KITCHEN', created: T0)
    }
  end

  def test_every_document_is_structurally_valid
    documents.each { |name, pdf| assert_operator assert_valid_pdf(pdf), :>=, 1, name }
  end

  def test_generation_is_deterministic_for_a_fixed_time
    a = documents
    b = documents
    a.each { |k, v| assert_equal v, b[k], k }
  end

  def test_label_sheet_holds_21_labels_per_page
    labels = Array.new(50) { |i| { 'project' => 'P', 'cabinet' => 'B01', 'part' => 'Side', 'part_id' => "B01-X#{i}", 'dimensions' => '1 x 2 x 3', 'qty' => 1, 'material' => 'm',
                                   'grain' => 'none', 'edge_banding' => '-', 'position' => 'x 0', 'override' => '', 'qr_payload' => "CC1|#{SecureRandom.uuid}|side_left" } }
    assert_equal 3, assert_valid_pdf(Reports.labels(labels, project: 'P', created: T0)) # ceil(50 / 21)
    assert_equal 1, assert_valid_pdf(Reports.labels([], project: 'P', created: T0))
  end

  def test_long_and_hostile_text_does_not_break_the_file
    rows = [{ 'part_id' => 'X' * 200, 'cabinet_label' => ")))(((\\", 'name' => "Ø × ° ² 木\nline", 'length' => 1.0, 'width' => 1.0, 'thickness' => 1.0, 'qty' => 1,
              'material' => 'm', 'grain' => 'none', 'edge_text' => '-', 'hardware' => 'h' * 500, 'status' => 'AUTO' }]
    assert_equal 1, assert_valid_pdf(Reports.parts_list(rows, project: "<script>(evil)\\</script>", created: T0))
  end

  # --- independent readers (dev machines with python + pypdf + pymupdf + opencv) ----------------------------------------
  def tool_available?
    _, st = Open3.capture2e('python3', '-c', 'import pypdf, fitz, cv2, numpy')
    st.success?
  end

  def test_pdfs_are_readable_by_independent_tools_and_qr_codes_decode
    skip 'python3 with pypdf, pymupdf and opencv not installed' unless tool_available?

    Dir.mktmpdir do |dir|
      cs = cabs
      labels = CabinetCraft::Manufacturing::Labels.build(cs, project_name: 'VALENTINA KITCHEN', qr: false)
      docs = documents
      spec = { 'files' => {}, 'qr' => labels.first(8).map { |l| l['qr_payload'] }, 'part_ids' => labels.map { |l| l['part_id'] }, 'project' => 'VALENTINA KITCHEN' }
      docs.each do |name, pdf|
        path = File.join(dir, "#{name}.pdf")
        File.binwrite(path, pdf)
        spec['files'][name] = path
      end
      out, st = Open3.capture2e('python3', File.join(__dir__, 'tools', 'pdf_check.py'), stdin_data: JSON.generate(spec))
      assert st.success?, out
      assert_includes out, 'ALL PDF CHECKS PASSED'
    end
  end
end
