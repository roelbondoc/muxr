$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Load only the pure pieces by default. Tests that need PTY-backed behavior
# can require "rux" directly.
require "rux/version"
require "rux/layout_manager"
require "rux/window"
require "rux/drawer"
require "rux/terminal"
require "rux/session"
