module Muxr
  module MouseReport
    WHEEL_UP = 64
    WHEEL_DOWN = 65
    X10_COORD_MAX = 223

    module_function

    def wheel(direction, row:, col:, encoding: :sgr)
      button = direction == :up ? WHEEL_UP : WHEEL_DOWN
      encoding == :sgr ? sgr(button, row, col) : x10(button, row, col)
    end

    def sgr(button, row, col)
      "\e[<#{button};#{[col, 1].max};#{[row, 1].max}M".b
    end

    def x10(button, row, col)
      c = col.clamp(1, X10_COORD_MAX)
      r = row.clamp(1, X10_COORD_MAX)
      "\e[M#{(32 + button).chr}#{(32 + c).chr}#{(32 + r).chr}".b
    end
  end
end
