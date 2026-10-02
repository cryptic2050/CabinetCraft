# frozen_string_literal: true

module CabinetCraft
  # Rule-based edge banding. Each panel role lists the faces that end up visible;
  # the band thickness comes from the cabinet parameters (0 = no banding).
  # Dimensions elsewhere are finished sizes: band thickness is NOT deducted.
  module EdgeBanding
    FRONT_FACES = %i[top bottom left right].freeze

    # role => [faces, band kind]
    RULES = {
      side: [%i[front], :carcass],
      bottom: [%i[front], :carcass],
      shelf: [%i[front], :carcass],
      fixed_shelf: [%i[front], :carcass],
      divider: [%i[front], :carcass],
      door: [FRONT_FACES, :front],
      drawer_front: [FRONT_FACES, :front]
    }.freeze

    module_function

    def apply(panel, params)
      faces, kind = RULES[panel.role]
      return panel unless faces

      mm = params[kind == :front ? 'edge_front' : 'edge_carcass'].to_f
      return panel unless mm.positive?

      panel.with_edges(faces.to_h { |f| [f, mm] })
    end
  end
end
