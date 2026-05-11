$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Load only the pure pieces by default. Tests that need PTY-backed behavior
# can require "muxr" directly.
require "muxr/version"
require "muxr/layout_manager"
require "muxr/window"
require "muxr/drawer"
require "muxr/terminal"
require "muxr/session"
require "muxr/protocol"
