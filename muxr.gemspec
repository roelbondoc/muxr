require_relative "lib/muxr/version"

Gem::Specification.new do |spec|
  spec.name          = "muxr"
  spec.version       = Muxr::VERSION
  spec.authors       = ["Roel Bondoc"]
  spec.email         = ["rsbondoc@gmail.com"]

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

  spec.metadata = {
    "source_code_uri"       => "https://github.com/roelbondoc/muxr",
    "bug_tracker_uri"       => "https://github.com/roelbondoc/muxr/issues",
    "changelog_uri"         => "https://github.com/roelbondoc/muxr/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
    "allowed_push_host"     => "https://rubygems.org"
  }

  spec.bindir        = "bin"
  spec.executables   = ["muxr", "muxr-mcp"]
  spec.files         = Dir[
    "lib/**/*.rb",
    "bin/muxr",
    "bin/muxr-mcp",
    "skills/**/*",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt",
    "muxr.gemspec"
  ]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
