#!/bin/sh
# Runs the pure-Ruby test suite (no SketchUp needed).
cd "$(dirname "$0")" && for f in tests/test_*.rb; do [ "$f" = tests/test_helper.rb ] && continue; ruby "$f" || exit 1; done
