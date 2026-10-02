# frozen_string_literal: true

require 'json'
require_relative 'controller'

module CabinetCraft
  # NOTE: named Interface (not UI) so it never shadows SketchUp's ::UI module.
  module Interface
    class SelectionWatcher < ::Sketchup::SelectionObserver
      def initialize(dashboard)
        super()
        @dashboard = dashboard
      end

      def onSelectionBulkChange(_selection)
        @dashboard.push_selection
      end

      def onSelectionCleared(_selection)
        @dashboard.push_selection
      end
    end

    # SketchUp keeps one window per model on Windows/macOS: when the user opens or creates another model the
    # dashboard must re-attach to that model's selection and drop everything cached for the old one.
    class ModelWatcher < ::Sketchup::AppObserver
      def initialize(dashboard)
        super()
        @dashboard = dashboard
      end

      def onNewModel(_model)
        @dashboard.model_changed
      end

      def onOpenModel(_model)
        @dashboard.model_changed
      end

      def onActivateModel(_model)
        @dashboard.model_changed
      end
    end

    class Dashboard
      class << self
        def show
          @instance ||= new
          @instance.show
        end

        # Menu entry: runs the in-model API self test and shows the result in a message box.
        def show_self_test
          r = Controller.new.self_test
          lines = r['checks'].map { |c| "#{c['ok'] ? 'PASS' : 'FAIL'}  #{c['name']}#{c['ok'] ? '' : " - #{c['detail']}"}" }
          ::UI.messagebox("SketchUp #{r['sketchup']}: #{r['total'] - r['failed']} of #{r['total']} checks passed\n\n#{lines.join("\n")}", ::MB_MULTILINE)
        end
      end

      def initialize
        @controller = Controller.new
        @dialog = nil
        @watcher = nil
        @watched_selection = nil
        @app_watcher = nil
      end

      # A different model became active: fresh controller (its caches belong to the old model), new observer, page reload.
      def model_changed
        return unless @dialog&.visible?

        @controller = Controller.new
        attach_selection_observer
        script('location.reload()')
      end

      def show
        if @dialog&.visible?
          @dialog.bring_to_front
          return
        end
        @dialog = build_dialog
        @dialog.show
        attach_selection_observer
        attach_app_observer
      end

      # Called by the selection observer: tell the page which cabinet (if any) is selected.
      def push_selection
        return unless @dialog&.visible?

        script("CC.onSelection(#{js_json(@controller.selected_summary)})")
      end

      private

      def build_dialog
        dlg = ::UI::HtmlDialog.new(
          dialog_title: 'CabinetCraft Pro', preferences_key: 'CabinetCraftPro.Dashboard',
          scrollable: false, resizable: true, width: 460, height: 780, min_width: 380, min_height: 480,
          style: ::UI::HtmlDialog::STYLE_DIALOG
        )
        dlg.set_file(File.join(CabinetCraft::PLUGIN_ROOT, 'ui', 'dashboard.html'))
        dlg.add_action_callback('rpc') { |_ctx, payload| handle_rpc(payload) }
        dlg.set_on_closed do
          detach_selection_observer
          detach_app_observer
        end
        dlg
      end

      def handle_rpc(payload)
        req = JSON.parse(payload)
        id = req['id']
        method = req['method'].to_s
        return export_with_dialog(id, Array(req['args'])) if method == 'export'

        unless Controller::PUBLIC_METHODS.include?(method)
          return reply(id, 'ok' => false, 'error' => "Unknown method #{method}")
        end

        reply(id, 'ok' => true, 'result' => @controller.public_send(method, *Array(req['args'])))
      rescue StandardError => e
        reply(id, 'ok' => false, 'error' => "#{e.class}: #{e.message}")
      end

      # Asks the user where to save, then writes the export. Cancel is not an error.
      def export_with_dialog(id, args)
        kind, format = args
        ext = Controller::EXTENSIONS.fetch(format.to_s) { raise ArgumentError, "Unknown format '#{format}'" }
        path = ::UI.savepanel('Export CabinetCraft data', nil, "cabinetcraft_#{kind}.#{ext}")
        return reply(id, 'ok' => true, 'result' => { 'ok' => false, 'cancelled' => true }) unless path

        reply(id, 'ok' => true, 'result' => @controller.export(kind, format, path))
      end

      def reply(id, message)
        script("CC.resolve(#{id.to_i}, #{js_json(message)})") if id
      end

      def script(code)
        @dialog&.execute_script(code)
      end

      # JSON that is also safe as a JavaScript expression.
      def js_json(obj)
        JSON.generate(obj).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
      end

      def attach_selection_observer
        detach_selection_observer
        @watched_selection = ::Sketchup.active_model.selection
        @watcher = SelectionWatcher.new(self)
        @watched_selection.add_observer(@watcher)
      end

      def attach_app_observer
        detach_app_observer
        @app_watcher = ModelWatcher.new(self)
        ::Sketchup.add_observer(@app_watcher)
      end

      def detach_app_observer
        ::Sketchup.remove_observer(@app_watcher) if @app_watcher
        @app_watcher = nil
      end

      def detach_selection_observer
        @watched_selection&.remove_observer(@watcher) if @watcher
        @watched_selection = nil
        @watcher = nil
      end
    end
  end
end
