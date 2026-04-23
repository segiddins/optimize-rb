# frozen_string_literal: true
require "prism"

module Optimize
  # Minimal parser for inline `@rbs` comments.
  #
  # Recognized form (one-line signature immediately preceding a def):
  #
  #   # @rbs (Type, Type, ...) -> Type
  #   def method_name(args...)
  #
  # Multi-line signatures, generics, block types, and rbs-inline's other
  # forms are out of scope for this plan.
  module RbsParser
    Signature = Struct.new(
      :method_name, :receiver_class, :arg_types, :return_type, :file, :line,
      keyword_init: true,
    )

    SIG_RE = /\A#\s*@rbs\s*\((.*?)\)\s*->\s*(\S+)/

    module_function

    def parse(source, file)
      result = Prism.parse(source)
      comment_by_line = {}
      result.comments.each do |c|
        comment_by_line[c.location.start_line] = c.slice
      end

      signatures = []
      walk(result.value, nil) do |node, class_ctx|
        next unless node.is_a?(Prism::DefNode)
        def_line = node.location.start_line
        rbs_text = scan_back_for_rbs(comment_by_line, def_line)
        next unless rbs_text
        match = SIG_RE.match(rbs_text)
        next unless match
        arg_types = split_arg_types(match[1])
        signatures << Signature.new(
          method_name: node.name,
          receiver_class: class_ctx,
          arg_types: arg_types,
          return_type: match[2],
          file: file,
          line: def_line,
        )
      end
      signatures
    end

    def walk(node, class_ctx, &block)
      return unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::ClassNode)
        new_ctx = node.constant_path.slice
        yield node, class_ctx
        node.compact_child_nodes.each { |c| walk(c, new_ctx, &block) }
      else
        yield node, class_ctx
        node.compact_child_nodes.each { |c| walk(c, class_ctx, &block) }
      end
    end

    def scan_back_for_rbs(comment_by_line, def_line)
      line = def_line - 1
      while line >= 1
        text = comment_by_line[line]
        return nil if text.nil?
        return text if text =~ /@rbs/
        line -= 1
      end
      nil
    end

    def split_arg_types(inside_parens)
      return [] if inside_parens.strip.empty?
      depth = 0
      buf = +""
      parts = []
      inside_parens.each_char do |ch|
        case ch
        when "(", "[", "<" then depth += 1; buf << ch
        when ")", "]", ">" then depth -= 1; buf << ch
        when ","
          if depth.zero?
            parts << buf.strip
            buf = +""
          else
            buf << ch
          end
        else
          buf << ch
        end
      end
      parts << buf.strip unless buf.empty?
      parts
    end
  end
end
