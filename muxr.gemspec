require_relative "lib/muxr/version"

Gem::Specification.new do |spec|
  spec.name          = "muxr"
  spec.version       = Muxr::VERSION
  spec.authors       = ["Roel Bondoc"]
  spec.email         = ["roel.bondoc@phoenix.ca"]

  spec.summary       = "A keyboard-driven terminal multiplexer with tiling layouts and a Quake-style drawer"
  spec.description   = <<~DESC
    muxr is a Ruby terminal multiplexer that combines GNU Screen's familiar
    keybindings, xmonad-inspired automatic tiling, and a Quake-style drop-down
    drawer overlay. Panes are treated as tiling clients: layouts are pure
    functions of pane count and screen dimensions, not user-resized regions.
  DESC
  spec.homepage      = "https://github.com/roelbondoc/muxr"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.bindir        = "bin"
  spec.executables   = ["muxr"]
  spec.files         = Dir[
    "lib/**/*.rb",
    "bin/muxr",
    "README.md",
    "LICENSE.txt",
    "muxr.gemspec"
  ]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
