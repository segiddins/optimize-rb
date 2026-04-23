# frozen_string_literal: true
require "diff/lcs"
require "diff/lcs/hunk"
require "ruby_opt/demo"
require "ruby_opt/demo/disasm_normalizer"

module RubyOpt
  module Demo
    module MarkdownRenderer
      PASS_DESCRIPTIONS = {
        inlining:         "Replace `send` with the callee's body when the receiver is resolvable.",
        dead_stash_elim:  "Drop `setlocal X; getlocal X` pairs whose slot has no other refs.",
        arith_reassoc:    "Reassociate `+ - * /` chains of literal operands under the no-BOP-redef rule.",
        const_fold:       "Fold literal-operand operations (Tier 1).",
        const_fold_tier2: "Rewrite frozen top-level constant references to their literal values.",
        const_fold_env:   "Fold `ENV[\"LITERAL\"]` reads against a snapshot captured at optimize time.",
        identity_elim:    "Remove identity operations: `x + 0`, `x * 1`, `x - 0`, `x / 1`.",
        dead_branch_fold: "Collapse `<literal>; branch*` into `jump` (taken) or a drop (not taken).",
      }.freeze

      module_function

      def render(stem:, source:, walkthrough:, snapshots:, bench:)
        prev_norm = DisasmNormalizer.normalize(snapshots.before)
        sections = []
        sections << heading(stem, bench, convergence: snapshots.convergence || {})
        sections << source_section(source)
        sections << summary_section(bench)
        sections << walkthrough_section(walkthrough, snapshots, prev_norm)
        sections << appendix_section(snapshots)
        sections << raw_benchmark_section(bench)
        sections.join("\n\n").rstrip + "\n"
      end

      def heading(stem, bench, convergence: {})
        ratio = bench.optimized_ips / bench.plain_ips
        lines = [
          "# #{stem} demo",
          "",
          "Pipeline.default: **#{format('%.2f', ratio)}x** vs unoptimized.",
        ]
        unless convergence.empty?
          max_iters = convergence.values.max
          lines << ""
          lines << "Converged in #{max_iters} iterations (max across functions)."
        end
        lines.join("\n")
      end

      def source_section(source)
        "## Source\n\n```ruby\n#{source.chomp}\n```"
      end

      def summary_section(bench)
        comparison = bench.stdout[/Comparison:.*/m] || ""
        "## Full-delta summary\n\n" \
          "`plain` = harness off; `optimized` = `Pipeline.default`.\n\n" \
          "```\n#{comparison.strip}\n```"
      end

      def walkthrough_section(walkthrough, snapshots, prev_norm)
        body = +"## Walkthrough\n\n"
        walkthrough.each do |name|
          current_norm = DisasmNormalizer.normalize(snapshots.per_pass.fetch(name))
          diff = unified_diff(prev_norm, current_norm, name)
          desc = PASS_DESCRIPTIONS[name] || "Pass `#{name}`."
          body << "### `#{name}`\n\n#{desc}\n\n```diff\n#{diff}```\n\n"
          prev_norm = current_norm
        end
        body.rstrip
      end

      def appendix_section(snapshots)
        "## Appendix: full iseq dumps\n\n" \
          "### Before (no optimization)\n\n```\n#{snapshots.before.rstrip}\n```\n\n" \
          "### After full `Pipeline.default`\n\n```\n#{snapshots.after_full.rstrip}\n```"
      end

      def raw_benchmark_section(bench)
        "## Raw benchmark output\n\n```\n#{bench.stdout.rstrip}\n```"
      end

      def unified_diff(a, b, label)
        a_lines = a.split("\n", -1)
        b_lines = b.split("\n", -1)
        diffs = Diff::LCS.diff(a_lines, b_lines)
        return "(no change)\n" if diffs.empty?

        out = +"--- before #{label}\n+++ after  #{label}\n"
        file_length_difference = 0
        diffs.each do |piece|
          hunk = Diff::LCS::Hunk.new(a_lines, b_lines, piece, 3, file_length_difference)
          file_length_difference = hunk.file_length_difference
          out << hunk.diff(:unified) << "\n"
        end
        out
      end
    end
  end
end
