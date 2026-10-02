# frozen_string_literal: true

require_relative '../scene/attributes'

module CabinetCraft
  module Interface
    # SketchUp tool for matching-grain sets: click the parts (cabinet parts or doors) in the order they should follow the
    # grain; right-click or Enter confirms them as one set (A1, A2, ...); Esc leaves the tool. Labels of existing sets are drawn
    # over the parts. Interactive picking and drawing can only be exercised inside SketchUp (see docs/LIMITATIONS.md).
    class GrainTool
      def initialize(controller)
        @controller = controller
        @picked = []
        @labels = []
      end

      def activate
        refresh_labels
        status
      end

      def deactivate(view)
        ::Sketchup.status_text = ''
        view.invalidate
      end

      def onSetCursor
        true
      end

      def onLButtonDown(_flags, x, y, view)
        uid = part_uid_at(view, x, y)
        return ::Sketchup.status_text = 'Click a cabinet part (open the cabinet group, or pick through it).' unless uid

        @picked.include?(uid) ? @picked.delete(uid) : @picked << uid
        status
        view.invalidate
      end

      def onRButtonDown(_flags, _x, _y, view)
        confirm(view)
      end

      def onKeyDown(key, _repeat, _flags, view)
        confirm(view) if key == 13 # Enter
      end

      def onCancel(_reason, view)
        @picked.clear
        ::Sketchup.active_model.select_tool(nil)
        view.invalidate
      end

      def draw(view)
        @labels.each { |l| view.draw_text(view.screen_coords(::Geom::Point3d.new(l['x'], l['y'], l['z'])), l['label']) }
      end

      private

      def confirm(view)
        if @picked.size < 2
          ::Sketchup.status_text = 'Pick at least two parts first.'
          return
        end
        @controller.assign_grain_set(@picked)
        @picked = []
        refresh_labels
        status
        view.invalidate
      rescue ArgumentError => e
        ::Sketchup.status_text = e.message
      end

      def refresh_labels
        @labels = @controller.grain_set_labels
      end

      def status
        ::Sketchup.status_text = "Click the parts that must follow the grain. Picked: #{@picked.size}. Right-click or Enter to confirm, Esc to finish."
      end

      def part_uid_at(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        path = ph.path_at(0) || []
        part = path.find { |e| e.respond_to?(:get_attribute) && !e.get_attribute(Scene::PART_DICT, 'part_uid').to_s.empty? }
        part&.get_attribute(Scene::PART_DICT, 'part_uid')
      end
    end
  end
end
