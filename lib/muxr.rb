require_relative "muxr/version"
require_relative "muxr/pty_process"
require_relative "muxr/terminal"
require_relative "muxr/pane"
require_relative "muxr/drawer"
require_relative "muxr/layout_manager"
require_relative "muxr/window"
require_relative "muxr/session"
require_relative "muxr/renderer"
require_relative "muxr/input_handler"
require_relative "muxr/command_dispatcher"
require_relative "muxr/protocol"
require_relative "muxr/control_server"
require_relative "muxr/application"
require_relative "muxr/client"

module Muxr
  class Error < StandardError; end
end
