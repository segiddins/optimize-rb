# Experiments

Single Ruby project shared across all experiments. Numbered subdirectories
correspond to a narrative arc that maps onto the talk outline.

## Layout

- `Gemfile` — shared dependencies
- `lib/` — helpers shared across experiments
- `NN-topic/` — one experiment, with its own `README.md` and one or more
  runnable `.rb` files

## Usage

    bundle install
    bundle exec rake list            # see what's here
    bundle exec ruby 01-iseq-basics/hello.rb

Prefer adding a new numbered directory over mutating an existing one —
experiments are journal entries, not production code.
