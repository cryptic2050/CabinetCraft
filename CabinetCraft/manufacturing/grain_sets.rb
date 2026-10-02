# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # "Matching grain" sets: parts that should be cut from the same board run so the grain continues across them
    # (for example the doors of a tall unit). A set has a letter; its parts are numbered in the order they were picked
    # (A1, A2, ...). Stored as { part_uid => 'A1' }. This is a labelling and reporting aid: the nesting does not keep
    # the parts of a set together (see docs/LIMITATIONS.md).
    module GrainSets
      module_function

      def letter(index)
        s = +''
        n = index
        loop do
          s.prepend((65 + n % 26).chr)
          n = n / 26 - 1
          break if n.negative?
        end
        s
      end

      def sets_of(map)
        map.group_by { |_, label| label[/\A[A-Z]+/] }.transform_values { |rows| rows.sort_by { |_, l| l[/\d+/].to_i }.map(&:first) }
      end

      def next_letter(map)
        used = sets_of(map).keys
        i = 0
        i += 1 while used.include?(letter(i))
        letter(i)
      end

      # Puts the parts (in the given order) into a new set. A part can only be in one set: it leaves any earlier one,
      # and the remaining parts of that set are renumbered without gaps.
      def assign(map, uids)
        uids = uids.uniq
        raise ArgumentError, 'Pick at least two parts for a matching-grain set' if uids.size < 2

        rest = map.reject { |uid, _| uids.include?(uid) }
        rest = renumber(rest)
        set = next_letter(rest)
        rest.merge(uids.each_with_index.to_h { |uid, i| [uid, "#{set}#{i + 1}"] })
      end

      def renumber(map)
        sets_of(map).flat_map do |set, uids|
          uids.size < 2 ? [] : uids.each_with_index.map { |uid, i| [uid, "#{set}#{i + 1}"] }
        end.to_h
      end

      # Drops parts that no longer exist and sets left with fewer than two parts.
      def clean(map, valid_uids)
        renumber(map.select { |uid, _| valid_uids.include?(uid) })
      end
    end
  end
end
