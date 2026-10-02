# frozen_string_literal: true

# Loads the extension the way SketchUp does (the file list in main.rb, in order, in a fresh process) against the
# mock API, then drives one full workflow. Catches files missing from main.rb and load-order mistakes.
require 'json'
require 'tmpdir'
root = File.expand_path('../../CabinetCraft', __dir__)
module CabinetCraft; end
CabinetCraft.const_set(:PLUGIN_ROOT, root)
CabinetCraft.const_set(:VERSION, 'test')
require File.expand_path('../mock_sketchup', __dir__)

src = File.read(File.join(root, 'main.rb'))
list = src[/%w\[(.*?)\]\.each/m, 1].split
list.each { |f| require File.join(root, f) }
# main.rb also registers menus/toolbars through ::UI; those are SketchUp-only and not part of this check.
missing = Dir.glob(File.join(root, '**/*.rb')).map { |f| f.sub("#{root}/", '').sub(/\.rb\z/, '') } - list - %w[main]
abort "files not loaded by main.rb: #{missing.inspect}" unless missing.empty?

c = CabinetCraft::Interface::Controller.new
boot = c.bootstrap
abort 'no library' if boot['library'].empty?
c.create('base_double_door', 'handle_type' => 'handle_bar')
c.create('base_drawer_3', {})
cab = c.list['cabinets'].first
c.set_override(cab['id'], 'side_left', 'edges' => { 'front' => 2 })
c.save_material('name' => 'Test board', 'thickness' => 19, 'role' => 'carcass', 'grain' => 'length', 'sheet_length' => 2440, 'sheet_width' => 1220, 'color' => '#aabbcc')
c.nest('kerf' => 8)
Dir.mktmpdir do |dir|
  %w[parts cutting_list labels nesting].each { |k| c.export(k, 'pdf', File.join(dir, "#{k}.pdf")) }
  c.export('dxf', 'dxf', File.join(dir, 'j.dxf'))
  c.export('gcode', 'nc', File.join(dir, 'j.nc'))
  c.export('project', 'json', File.join(dir, 'j.json'))
end
v = c.validate
puts "LOAD OK: #{list.size} files, #{c.parts_list['rows'].size} parts, validation #{v['summary']['status']}"
