# frozen_string_literal: true

module CabinetCraft
  # All internal lengths are millimetres. Conversion happens only at the edges:
  #  - display/input (mm, cm, m, in)
  #  - the SketchUp API, whose native length unit is the inch.
  module Units
    MM_PER_UNIT = { 'mm' => 1.0, 'cm' => 10.0, 'm' => 1000.0, 'in' => 25.4 }.freeze
    PRECISION   = { 'mm' => 1, 'cm' => 2, 'm' => 4, 'in' => 3 }.freeze
    MM_PER_INCH = 25.4

    module_function

    def supported?(unit)
      MM_PER_UNIT.key?(unit)
    end

    def to_mm(value, unit)
      value.to_f * MM_PER_UNIT.fetch(unit)
    end

    def from_mm(mm, unit)
      mm.to_f / MM_PER_UNIT.fetch(unit)
    end

    # Millimetres -> SketchUp internal length (inches).
    def to_sketchup(mm)
      mm.to_f / MM_PER_INCH
    end

    # SketchUp internal length (inches) -> millimetres.
    def from_sketchup(inches)
      inches.to_f * MM_PER_INCH
    end

    def format(mm, unit = 'mm')
      "#{from_mm(mm, unit).round(PRECISION.fetch(unit))} #{unit}"
    end
  end
end
