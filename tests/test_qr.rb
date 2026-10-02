# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require File.join(CabinetCraft::PLUGIN_ROOT, 'utilities/qr_code')

class TestQr < Minitest::Test
  Q = CabinetCraft::QrCode

  def test_sizes_and_finder_patterns
    { 'A' => 21, 'x' * 15 => 25, 'y' * 60 => 33, 'z' * 213 => 57 }.each do |text, size|
      m = Q.encode(text)
      assert_equal size, m.size
      [[0, 0], [0, size - 7], [size - 7, 0]].each do |r, c|
        assert m[r][c] && m[r][c + 6] && m[r + 6][c] && m[r + 6][c + 6], 'finder corners dark'
        refute m[r + 1][c + 1], 'finder ring is light'
        assert m[r + 3][c + 3], 'finder centre dark'
      end
      assert m[size - 8][8], 'dark module present'
    end
  end

  def test_deterministic
    assert_equal Q.encode('CC1|abc|side_left'), Q.encode('CC1|abc|side_left')
  end

  def test_too_long_raises
    assert_raises(Q::TooLong) { Q.encode('x' * 214) }
    assert Q.encode('x' * 213)
  end

  def test_unicode_is_encoded_as_utf8_bytes
    assert Q.encode('木工')
  end

  def test_svg_is_well_formed
    svg = Q.svg('hello')
    assert svg.start_with?('<svg') && svg.end_with?('</svg>')
    assert_match(/viewBox="0 0 29 29"/, svg) # 21 modules + 2 * 4 quiet
  end

  # Independent verification against the python-qrcode reference (dev machines only).
  def test_matches_reference_implementation_when_available
    _, status = Open3.capture2e('python3', '-c', 'import qrcode')
    skip 'python3 + qrcode not installed' unless status.success?

    srand(11)
    cases = (1..213).step(7).map { |n| Array.new(n) { (rand(94) + 33).chr }.join } + ['CC1|3f2b1c9e-5d7a-4c1e-9b0a-1f2e3d4c5b6a|drawer_3_side_right']
    input = cases.map { |t| "#{t}\n#{Q.to_text(t)}" }.join("\n---\n")
    out, st = Open3.capture2e('python3', File.join(__dir__, 'tools', 'qr_crosscheck.py'), stdin_data: input)
    assert st.success?, out
    assert_match(/0 with no identical reference matrix/, out)
  end
end
