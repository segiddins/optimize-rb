# 02 — load_iseq hook

Demonstrates `RubyVM::InstructionSequence.load_iseq` as the seam for
swapping a method's bytecode at load time.

    bundle exec ruby 02-load-iseq-hook/driver.rb

Expected: `Greeter#greet` runs with *rewritten* bytecode that the hook
installed in place of the iseq MRI would have compiled from `target.rb`.

## Files

- `target.rb` — the "production" file; defines `Greeter#greet`
- `driver.rb` — installs the `load_iseq` hook, requires `target`, then
  disassembles the resulting method to prove which iseq won

## Your turn

Open `driver.rb` and implement `rewrite_source`. See the TODO — this is
where the pedagogical choice lives.
