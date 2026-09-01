# The local one-word gate. CI runs the same commands, one job each, so that a
# red check names itself instead of being a log to go and read.
.PHONY: check fmt lint test format install

check: fmt lint test

fmt:
	stylua --check .

lint:
	luacheck .

test:
	busted --coverage
	luacov
	lua scripts/coverage-floor.lua
	bats spec/*.bats

# Rewrites the files rather than checking them. Never run in CI.
format:
	stylua .

install:
	./scripts/install.sh
