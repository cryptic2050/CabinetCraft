# frozen_string_literal: true

module CabinetCraft
  # Runs the SketchUp API calls CabinetCraft depends on against the REAL model and reports which ones behave as the
  # code assumes. The unit tests use a mock SketchUp; this is the check that the mock matches the real thing.
  # Everything happens inside one operation that is aborted afterwards, so the user's model is left unchanged.
  module SelfTest
    Check = Struct.new(:name, :ok, :detail)

    module_function

    def run(model = ::Sketchup.active_model)
      results = []
      model.start_operation('CabinetCraft: self test', true)
      begin
        checks(model).each do |name, body|
          detail = body.call
          results << Check.new(name, detail == true, detail == true ? '' : detail.to_s)
        rescue StandardError => e
          results << Check.new(name, false, "#{e.class}: #{e.message}")
        end
      ensure
        model.abort_operation
      end
      summary(results)
    end

    def summary(results)
      failed = results.reject(&:ok)
      {
        'ok' => failed.empty?, 'total' => results.size, 'failed' => failed.size,
        'sketchup' => defined?(::Sketchup::Version) ? ::Sketchup.version.to_s : 'unknown',
        'checks' => results.map { |c| { 'name' => c.name, 'ok' => c.ok, 'detail' => c.detail } }
      }
    end

    def near(a, b, tol = 0.01)
      (a - b).abs <= tol
    end

    def checks(model)
      ents = model.entities
      pt = ->(x, y, z) { ::Geom::Point3d.new(x, y, z) }
      {
        'extrude a face into a panel (inches)' => lambda {
          g = ents.add_group
          f = g.entities.add_face([pt.call(0, 0, 0), pt.call(10, 0, 0), pt.call(10, 5, 0), pt.call(0, 5, 0)])
          f.reverse! if f.normal.z < 0
          f.pushpull(2)
          b = g.bounds
          dims = [b.width, b.height, b.depth].map { |v| v.to_f.round(3) }.sort
          dims == [2.0, 5.0, 10.0] || "bounds were #{dims.inspect}, expected 2 x 5 x 10 in"
        },
        'attributes round-trip on a group' => lambda {
          g = ents.add_group
          g.set_attribute('CabinetCraft_Test', 'k', 'v')
          g.set_attribute('CabinetCraft_Test', 'n', 12.5)
          g.get_attribute('CabinetCraft_Test', 'k') == 'v' && g.get_attribute('CabinetCraft_Test', 'n') == 12.5 || 'attribute read-back differs'
        },
        'attribute_dictionary enumerates' => lambda {
          g = ents.add_group
          g.set_attribute('CabinetCraft_Test', 'a', 1)
          d = g.attribute_dictionary('CabinetCraft_Test')
          keys = []
          d.each_pair { |k, _| keys << k }
          keys == ['a'] || "keys were #{keys.inspect}"
        },
        'model attributes round-trip' => lambda {
          model.set_attribute('CabinetCraft_SelfTest', 'x', 'y')
          model.get_attribute('CabinetCraft_SelfTest', 'x') == 'y' || 'model attribute read-back differs'
        },
        'transform! composes after the existing transformation' => lambda {
          g = ents.add_group
          g.entities.add_face([pt.call(0, 0, 0), pt.call(1, 0, 0), pt.call(1, 1, 0), pt.call(0, 1, 0)])
          g.transform!(::Geom::Transformation.new(pt.call(10, 0, 0)))
          g.transform!(::Geom::Transformation.new(pt.call(0, 5, 0)))
          o = g.transformation.origin
          near(o.x, 10) && near(o.y, 5) || "origin was #{o.to_a.inspect}, expected [10, 5, 0]"
        },
        'rotated transformation keeps axes' => lambda {
          t = ::Geom::Transformation.new(pt.call(0, 0, 0), ::Geom::Vector3d.new(0, 1, 0), ::Geom::Vector3d.new(-1, 0, 0))
          x = t.xaxis
          near(x.x, 0, 1e-6) && near(x.y, 1, 1e-6) || "xaxis was #{x.to_a.inspect}"
        },
        'make_unique and clear!' => lambda {
          g = ents.add_group
          g.entities.add_face([pt.call(0, 0, 0), pt.call(1, 0, 0), pt.call(1, 1, 0)])
          g.make_unique if g.respond_to?(:make_unique)
          g.entities.clear!
          g.entities.to_a.empty? || 'clear! left entities behind'
        },
        'component definition and instance' => lambda {
          d = model.definitions.add('CabinetCraft self test')
          d.entities.add_face([pt.call(0, 0, 0), pt.call(1, 0, 0), pt.call(1, 1, 0)])
          i = ents.add_instance(d, ::Geom::Transformation.new(pt.call(3, 0, 0)))
          i.make_unique
          near(i.transformation.origin.x, 3) || 'instance transformation not applied'
        },
        'materials accept colour and alpha' => lambda {
          m = model.materials.add('CabinetCraft self test material')
          m.color = ::Sketchup::Color.new(10, 20, 30)
          m.alpha = 0.5
          g = ents.add_group
          g.material = m
          g.material.equal?(m) && near(m.alpha, 0.5, 1e-6) || 'material assignment or alpha failed'
        },
        'erase! removes an entity' => lambda {
          g = ents.add_group
          g.erase!
          !ents.include?(g) || 'erase! left the group in place'
        },
        'a generated cabinet matches its part list and can be found again' => lambda {
          params = Library.defaults_for('base_cabinet')
          cab = Cabinet.build(type: 'base_cabinet', params: params, label: 'ST01')
          group = Generators::CabinetGenerator.create(ents, cab)
          bad = group.entities.grep(::Sketchup::Group).filter_map do |part|
            row = cab.part_rows.find { |r| cab.part_id(cab.panels.find { |pn| pn.key == r['key'] }) == part.name }
            next "no row for #{part.name}" unless row

            dims = [part.bounds.width, part.bounds.height, part.bounds.depth].map { |v| Units.from_sketchup(v) }.sort
            want = [row['length'], row['width'], row['thickness']].map(&:to_f).sort
            "#{part.name}: #{dims.map { |v| v.round(1) }} vs #{want}" unless dims.zip(want).all? { |d, w| near(d, w, 0.1) }
          end
          next bad.first(3).join('; ') unless bad.empty?

          Scene::Registry.find(model, cab.id).nil? ? 'registry could not find the generated cabinet' : true
        }
      }
    end
  end
end
