# frozen_string_literal: true

module CabinetCraft
  # Minimal, dependency-free QR Code encoder (ISO/IEC 18004): byte mode,
  # error-correction level M, versions 1-10 (up to 213 bytes). Original code;
  # SketchUp's Ruby ships no QR library. Output is a boolean matrix (true = dark).
  module QrCode
    class TooLong < StandardError; end

    # version => [data codewords, EC codewords per block, [[block count, data codewords per block], ...]]  (level M)
    BLOCKS = {
      1 => [16, 10, [[1, 16]]], 2 => [28, 16, [[1, 28]]], 3 => [44, 26, [[1, 44]]], 4 => [64, 18, [[2, 32]]],
      5 => [86, 24, [[2, 43]]], 6 => [108, 16, [[4, 27]]], 7 => [124, 18, [[4, 31]]],
      8 => [154, 22, [[2, 38], [2, 39]]], 9 => [182, 22, [[3, 36], [2, 37]]], 10 => [216, 26, [[4, 43], [1, 44]]]
    }.freeze

    ALIGNMENT = {
      1 => [], 2 => [6, 18], 3 => [6, 22], 4 => [6, 26], 5 => [6, 30], 6 => [6, 34],
      7 => [6, 22, 38], 8 => [6, 24, 42], 9 => [6, 26, 46], 10 => [6, 28, 50]
    }.freeze

    ECC_M_BITS = 0 # format-info indicator for level M

    MASKS = [
      ->(r, c) { ((r + c) % 2).zero? }, ->(r, _c) { (r % 2).zero? }, ->(_r, c) { (c % 3).zero? },
      ->(r, c) { ((r + c) % 3).zero? }, ->(r, c) { ((r / 2 + c / 3) % 2).zero? },
      ->(r, c) { ((r * c) % 2 + (r * c) % 3).zero? }, ->(r, c) { (((r * c) % 2 + (r * c) % 3) % 2).zero? },
      ->(r, c) { (((r * c) % 3 + (r + c) % 2) % 2).zero? }
    ].freeze

    # --- GF(256) / Reed-Solomon ---------------------------------------------------
    EXP = Array.new(512)
    LOG = Array.new(256)
    x = 1
    255.times do |i|
      EXP[i] = x
      LOG[x] = i
      x <<= 1
      x ^= 0x11D if x & 0x100 != 0
    end
    (255..511).each { |i| EXP[i] = EXP[i - 255] }

    module_function

    def gf_mul(a, b)
      return 0 if a.zero? || b.zero?

      EXP[LOG[a] + LOG[b]]
    end

    def generator_poly(degree)
      poly = [1]
      degree.times do |i|
        next_poly = Array.new(poly.size + 1, 0)
        poly.each_with_index do |coef, j|
          next_poly[j] ^= coef
          next_poly[j + 1] ^= gf_mul(coef, EXP[i])
        end
        poly = next_poly
      end
      poly
    end

    def ec_codewords(data, ec_count)
      gen = generator_poly(ec_count)
      msg = data + Array.new(ec_count, 0)
      data.size.times do |i|
        coef = msg[i]
        next if coef.zero?

        gen.each_with_index { |g, j| msg[i + j] ^= gf_mul(g, coef) }
      end
      msg[data.size, ec_count]
    end

    # --- Encoding ---------------------------------------------------------------------
    def encode(text)
      bytes = text.to_s.encode('UTF-8').bytes
      version = (1..10).find { |v| fits?(bytes.size, v) } or raise TooLong, "#{bytes.size} bytes is too long for a version 10 code"
      codewords = interleave(data_codewords(bytes, version), version)
      build_matrix(codewords, version)
    end

    def fits?(len, version)
      count_bits = version <= 9 ? 8 : 16
      4 + count_bits + 8 * len <= 8 * BLOCKS[version][0]
    end

    def data_codewords(bytes, version)
      bits = +''
      bits << '0100' << bytes.size.to_s(2).rjust(version <= 9 ? 8 : 16, '0')
      bytes.each { |b| bits << b.to_s(2).rjust(8, '0') }
      capacity = BLOCKS[version][0] * 8
      bits << '0' * [4, capacity - bits.size].min
      bits << '0' * ((8 - bits.size % 8) % 8)
      words = bits.scan(/.{8}/).map { |b| b.to_i(2) }
      pad = [0xEC, 0x11]
      words << pad[(words.size - bits.size / 8) % 2] while words.size < BLOCKS[version][0]
      words
    end

    def interleave(data, version)
      _, ec_len, groups = BLOCKS[version]
      blocks = []
      pos = 0
      groups.each do |count, size|
        count.times do
          blocks << data[pos, size]
          pos += size
        end
      end
      ecs = blocks.map { |b| ec_codewords(b, ec_len) }
      out = []
      blocks.map(&:size).max.times { |i| blocks.each { |b| out << b[i] if i < b.size } }
      ec_len.times { |i| ecs.each { |e| out << e[i] } }
      out
    end

    # --- Matrix construction -----------------------------------------------------------
    def build_matrix(codewords, version)
      size = 17 + 4 * version
      best = nil
      8.times do |mask|
        m = Array.new(size) { Array.new(size) }
        place_function_patterns(m, version, size)
        place_data(m, codewords, size, mask)
        place_format_info(m, mask, size)
        place_version_info(m, version, size) if version >= 7
        score = penalty(m, size)
        best = [score, m] if best.nil? || score < best[0]
      end
      best[1].map { |row| row.map { |v| v ? true : false } }
    end

    def place_function_patterns(m, version, size)
      [[0, 0], [0, size - 7], [size - 7, 0]].each { |r, c| finder(m, r, c, size) }
      8.upto(size - 9) do |i|
        m[6][i] = i.even? if m[6][i].nil?
        m[i][6] = i.even? if m[i][6].nil?
      end
      pos = ALIGNMENT[version]
      finder_corners = [[pos.first, pos.first], [pos.first, pos.last], [pos.last, pos.first]]
      pos.each do |r|
        pos.each do |c|
          next if finder_corners.include?([r, c]) # would overlap a finder; others (even on the timing line) are drawn

          (-2..2).each { |dr| (-2..2).each { |dc| m[r + dr][c + dc] = dr.abs == 2 || dc.abs == 2 || (dr.zero? && dc.zero?) } }
        end
      end
      m[size - 8][8] = true # always-dark module
      reserve_format_areas(m, version, size)
    end

    def finder(m, r0, c0, size)
      (-1..7).each do |dr|
        (-1..7).each do |dc|
          r = r0 + dr
          c = c0 + dc
          next unless r.between?(0, size - 1) && c.between?(0, size - 1)

          inside = dr.between?(0, 6) && dc.between?(0, 6)
          ring = dr.zero? || dr == 6 || dc.zero? || dc == 6
          core = dr.between?(2, 4) && dc.between?(2, 4)
          m[r][c] = inside && (ring || core)
        end
      end
    end

    # Mark format/version areas as "reserved" (false) so data placement skips them; they are filled later.
    def reserve_format_areas(m, version, size)
      9.times do |i|
        m[8][i] = false if m[8][i].nil?
        m[i][8] = false if m[i][8].nil?
      end
      8.times do |i|
        m[8][size - 1 - i] = false if m[8][size - 1 - i].nil?
        m[size - 1 - i][8] = false if m[size - 1 - i][8].nil?
      end
      return unless version >= 7

      6.times { |i| 3.times { |j| m[i][size - 11 + j] = false; m[size - 11 + j][i] = false } }
    end

    def function_modules(version, size)
      m = Array.new(size) { Array.new(size) }
      place_function_patterns(m, version, size)
      m.map { |row| row.map { |v| !v.nil? } }
    end

    def place_data(m, codewords, size, mask)
      fn = function_modules(version_of(size), size)
      bits = codewords.flat_map { |cw| 8.times.map { |i| (cw >> (7 - i)) & 1 } }
      idx = 0
      up = true
      col = size - 1
      while col.positive?
        col -= 1 if col == 6
        rows = up ? (size - 1).downto(0).to_a : (0...size).to_a
        rows.each do |r|
          [col, col - 1].each do |c|
            next if fn[r][c]

            bit = idx < bits.size && bits[idx] == 1
            idx += 1
            bit = !bit if MASKS[mask].call(r, c)
            m[r][c] = bit
          end
        end
        up = !up
        col -= 2
      end
    end

    def version_of(size)
      (size - 17) / 4
    end

    def bch(value, poly, shift)
      d = value << shift
      poly_len = poly.bit_length
      d ^= poly << (d.bit_length - poly_len) while d.bit_length >= poly_len
      (value << shift) | d
    end

    def place_format_info(m, mask, size)
      bits = bch((ECC_M_BITS << 3) | mask, 0x537, 10) ^ 0x5412
      15.times do |i|
        dark = ((bits >> i) & 1) == 1
        if i < 6 then m[i][8] = dark
        elsif i < 8 then m[i + 1][8] = dark
        else m[size - 15 + i][8] = dark
        end
        if i < 8 then m[8][size - i - 1] = dark
        elsif i < 9 then m[8][15 - i] = dark
        else m[8][15 - i - 1] = dark
        end
      end
      m[size - 8][8] = true
    end

    def place_version_info(m, version, size)
      bits = bch(version, 0x1F25, 12)
      18.times do |i|
        dark = ((bits >> i) & 1) == 1
        m[i / 3][i % 3 + size - 11] = dark
        m[i % 3 + size - 11][i / 3] = dark
      end
    end

    # --- Mask penalty (ISO 18004 rules N1-N4) ---------------------------------------------
    def penalty(m, size)
      score = 0
      lines = m + m.transpose
      lines.each do |line|
        run = 1
        (1...size).each do |i|
          if line[i] == line[i - 1]
            run += 1
          else
            score += run - 2 if run >= 5
            run = 1
          end
        end
        score += run - 2 if run >= 5
      end
      (0...size - 1).each do |r|
        (0...size - 1).each do |c|
          v = m[r][c]
          score += 3 if v == m[r][c + 1] && v == m[r + 1][c] && v == m[r + 1][c + 1]
        end
      end
      pat1 = [true, false, true, true, true, false, true, false, false, false, false]
      pat2 = pat1.reverse
      lines.each do |line|
        (0..size - 11).each do |i|
          seg = line[i, 11]
          score += 40 if seg == pat1 || seg == pat2
        end
      end
      dark = m.sum { |row| row.count(true) }
      score + ((dark * 100.0 / (size * size) - 50).abs / 5).floor * 10
    end

    # --- Output --------------------------------------------------------------------------
    # SVG string; `quiet` modules of white border (4 is the QR standard).
    def svg(text, quiet: 4, dark: '#000', light: '#fff')
      m = encode(text)
      n = m.size + 2 * quiet
      path = +''
      m.each_with_index do |row, r|
        c = 0
        while c < row.size
          if row[c]
            start = c
            c += 1 while c < row.size && row[c]
            path << "M#{start + quiet} #{r + quiet}h#{c - start}v1h-#{c - start}z"
          else
            c += 1
          end
        end
      end
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{n} #{n}" shape-rendering="crispEdges">) +
        %(<rect width="#{n}" height="#{n}" fill="#{light}"/><path d="#{path}" fill="#{dark}"/></svg>)
    end

    # '1'/'0' lines, used by the decode-verification script.
    def to_text(text)
      encode(text).map { |row| row.map { |v| v ? '1' : '0' }.join }.join("\n")
    end
  end
end
