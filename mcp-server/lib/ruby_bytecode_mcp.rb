# frozen_string_literal: true

require "mcp"

module RubyBytecodeMcp
  DEFAULT_RUBY_VERSION = "4.0.2"
  DEFAULT_IMAGE_PREFIX = "ruby"
  DEFAULT_IMAGE_SUFFIX = "-slim"
  DEFAULT_TIMEOUT_S = 30
end

require_relative "ruby_bytecode_mcp/docker_runner"
require_relative "ruby_bytecode_mcp/server"
