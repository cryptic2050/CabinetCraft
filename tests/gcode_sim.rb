# frozen_string_literal: true

# A tiny G-code interpreter for TESTS ONLY. It understands exactly the dialect our posts emit
# (absolute positioning, G0/G1/G81/G80/G98, T/M6, S/M3/M5, units G20/G21) and records what a
# machine would do, so tests can compare the real output text against the planned operations.
class GcodeSim
  Result = Struct.new(:drills, :moves, :tools, :violations, :ended, :units, keyword_init: true)

  def self.run(text, surface_top: 0.0, safe_floor: 1.0)
    pos = { 'X' => 0.0, 'Y' => 0.0, 'Z' => 20.0 }
    factor = 1.0
    units = 'mm'
    tool = nil
    drills = []
    moves = [] # { type:, from:, to:, tool:, f: }
    tools = []
    violations = []
    ended = false
    canned = nil
    text.each_line do |raw|
      if (m = raw.match(/\AM0 \(Change to T(\d+)/)) # GRBL-style operator pause names the tool in its comment
        tool = m[1].to_i
        tools << tool
      end
      line = raw.sub(/\(.*\)/, '').strip
      next if line.empty? || line.start_with?('%')

      line = line.sub(/\AN\d+\s*/, '')
      words = line.scan(/([A-Z])(-?\d+\.?\d*)/).map { |l, v| [l, v.to_f] }
      codes = words.select { |l, _| %w[G M].include?(l) }.map { |l, v| "#{l}#{v.to_i}" }
      axis = words.select { |l, _| %w[X Y Z].include?(l) }.to_h
      get = ->(l) { words.find { |x, _| x == l }&.last }
      codes.each do |c|
        case c
        when 'G20' then factor = 25.4; units = 'in'
        when 'G21' then factor = 1.0; units = 'mm'
        when 'G80' then canned = nil
        when 'M30', 'M2' then ended = true
        end
      end
      if get.call('T') && codes.include?('M6')
        tool = get.call('T').to_i
        tools << tool
      end
      mm = ->(v) { v * factor }
      if codes.include?('G81')
        canned = { r: mm.call(get.call('R')), f: get.call('F') }
        target = pos.merge(axis.transform_values { |v| mm.call(v) })
        drills << { tool: tool, x: target['X'], y: target['Y'], z: target['Z'], r: canned[:r], via: :canned }
        pos['X'] = target['X']
        pos['Y'] = target['Y'] # canned cycle returns to R (G98 -> initial); Z unchanged for our purposes
      elsif codes.include?('G0') || codes.include?('G1')
        from = pos.dup
        axis.each { |a, v| pos[a] = mm.call(v) }
        type = codes.include?('G0') ? :rapid : :cut
        moved_xy = (from['X'] != pos['X'] || from['Y'] != pos['Y'])
        violations << "XY move below the safe plane at z=#{from['Z']}: #{raw.strip}" if moved_xy && type == :rapid && from['Z'] < safe_floor && from['Z'] < pos['Z'] + 1e-9 && pos['Z'] < safe_floor
        violations << "rapid XY move while z=#{pos['Z']} is inside the material: #{raw.strip}" if moved_xy && type == :rapid && [from['Z'], pos['Z']].min < surface_top - 1e-9
        moves << { type: type, from: from, to: pos.dup, tool: tool, f: get.call('F') }
      end
    end
    Result.new(drills: drills, moves: moves, tools: tools, violations: violations, ended: ended, units: units)
  end

  # Plunge moves at an XY followed by cutting: treat explicit G0/G1 drill sequences (non-canned) as drills.
  def self.explicit_drills(moves, surface_top: 0.0)
    drills = []
    moves.each_cons(2) do |a, b|
      next unless b[:type] == :cut && a[:to]['X'] == b[:to]['X'] && a[:to]['Y'] == b[:to]['Y'] && b[:to]['Z'] < surface_top - 1e-9 && b[:from]['Z'] > b[:to]['Z']
      next unless b[:from]['X'] == b[:to]['X'] && b[:from]['Y'] == b[:to]['Y']

      drills << { tool: b[:tool], x: b[:to]['X'], y: b[:to]['Y'], z: b[:to]['Z'] }
    end
    drills
  end
end
