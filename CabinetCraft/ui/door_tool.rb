# frozen_string_literal: true

require_relative '../scene/attributes'

module CabinetCraft
  module Interface
    # SketchUp tool: click a cabinet to open or close its doors; Escape (or choosing another tool) ends it.
    # Interactive picking can only be exercised inside SketchUp (see the self test and docs/LIMITATIONS.md).
    class DoorTool
      def initialize(controller)
        @controller = controller
      end

      def activate
        ::Sketchup.status_text = 'Click a cabinet to open or close its doors. Esc to finish.'
      end

      def deactivate(view)
        ::Sketchup.status_text = ''
        view.invalidate
      end

      def onSetCursor
        true
      end

      def onLButtonDown(_flags, x, y, view)
        id = cabinet_id_at(view, x, y)
        unless id
          ::Sketchup.status_text = 'No CabinetCraft cabinet under the cursor.'
          return
        end
        r = @controller.toggle_doors([id])
        ::Sketchup.status_text = r['ok'] ? (r['open'] ? 'Doors opened.' : 'Doors closed.') : r['error'].to_s
        view.invalidate
      end

      def onCancel(_reason, view)
        ::Sketchup.active_model.select_tool(nil)
        view.invalidate
      end

      private

      # The outermost picked entity that carries cabinet data (cabinets may sit inside other groups).
      def cabinet_id_at(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        path = ph.path_at(0) || []
        group = path.find { |e| e.respond_to?(:get_attribute) && !e.get_attribute(CABINET_DICT, 'cabinet_id').to_s.empty? }
        group&.get_attribute(CABINET_DICT, 'cabinet_id')
      end
    end
  end
end
