# The local one-word gate. CI runs the same commands, one job each, so that a
# red check names itself instead of being a log to go and read.
.PHONY: check fmt lint test format install

check: fmt lint test

fmt:
	stylua --check .

lint:
	luacheck .
	./scripts/leak-lint.sh

# luacov *adds to* luacov.stats.out rather than replacing it, so a second run in
# the same checkout counts every line the first run hit as well. Left alone, the
# reported percentage climbs with the number of times anybody has run the tests,
# and the figure quoted in a commit message is whatever that count happened to
# be. CI never saw it, because a fresh checkout has no stats file to inherit.
test:
	rm -f luacov.stats.out luacov.report.out
	busted --coverage
	luacov
	lua scripts/coverage-floor.lua
	bats spec/*.bats

# Rewrites the files rather than checking them. Never run in CI.
format:
	stylua .

install:
	./scripts/install.sh
