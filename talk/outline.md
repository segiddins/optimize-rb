# Ruby the Hard Way: Writing Bytecode to Optimize Plain Ruby

Prose outline. Content TBD — structure only for now.

## 0. Cold open

Hook: a production hotspot that refused to yield to profiling and
refactoring.

## 1. Why bytecode?

What's left when you've exhausted "write better Ruby".

## 2. From source to YARV

The compilation pipeline, in enough detail to write bytecode by hand.

## 3. Writing bytecode by hand

`RubyVM::InstructionSequence.compile`, `.load_from_binary`, the shape of
the iseq array.

## 4. Replacing a hot method

A worked example: identify, compile, swap, measure.

## 5. Tradeoffs

Portability, debuggability, maintenance, Ruby version drift.

## 6. When to reach for this

And, more importantly, when not to.

## 7. Close

Call to action / links / questions.
