# frozen_string_literal: true

# Dev harness: serves the real Controller (on the mock SketchUp model) over
# stdin/stdout JSON lines so the dashboard can be exercised in a plain browser.
require_relative 'test_helper'
require_relative 'mock_sketchup'
%w[generators/cabinet_generator scene/attributes scene/registry ui/controller].each { |f| require File.join(CabinetCraft::PLUGIN_ROOT, f) }
$stdout.sync = true
c = CabinetCraft::Interface::Controller.new
$stdin.each_line do |line|
  req = JSON.parse(line)
  out = begin
    { 'ok' => true, 'result' => c.public_send(req['method'], *req['args']) }
  rescue StandardError => e
    { 'ok' => false, 'error' => e.message }
  end
  puts JSON.generate(out)
end
