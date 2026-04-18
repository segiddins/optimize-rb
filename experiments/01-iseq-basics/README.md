# 01 — ISeq basics

Smoke test confirming the experiments harness works:

    bundle exec ruby 01-iseq-basics/hello.rb

Expected: the Ruby version and a disassembly containing `putobject 1`,
`putobject 2`, and `opt_plus`.
