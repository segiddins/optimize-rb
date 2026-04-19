# frozen_string_literal: true

require "minitest/autorun"
require "ruby_bytecode_mcp"

module TestHelper
  def docker_available?
    system("docker info > /dev/null 2>&1")
  end

  def skip_without_docker!
    skip "Docker is not available on this host" unless docker_available?
  end
end
