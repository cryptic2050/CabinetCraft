# frozen_string_literal: true

# Dev harness: serves the real Controller (on the mock SketchUp model) over
# stdin/stdout JSON lines so the dashboard can be exercised in a plain browser.
require_relative 'test_helper'
require_relative 'mock_sketchup'
%w[generators/cabinet_generator scene/attributes scene/registry scene/settings_store ui/controller].each { |f| require File.join(CabinetCraft::PLUGIN_ROOT, f) }
require 'tmpdir'
$stdout.sync = true
c = CabinetCraft::Interface::Controller.new
$stdin.each_line do |line|
  req = JSON.parse(line)
  out = begin
    if req['method'] == 'export' # the real dialog asks via UI.savepanel; here we write to a temp dir
      kind, fmt = req['args']
      ext = CabinetCraft::Interface::Controller::EXTENSIONS.fetch(fmt, 'csv')
      { 'ok' => true, 'result' => c.export(kind, fmt, File.join(Dir.tmpdir, "cc_#{kind}.#{ext}")) }
    else
      { 'ok' => true, 'result' => c.public_send(req['method'], *req['args']) }
    end
  rescue StandardError => e
    { 'ok' => false, 'error' => e.message }
  end
  puts JSON.generate(out)
end
