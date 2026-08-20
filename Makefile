# mail2rss26 — thin wrappers around the commands this repo needs.
#
# Nothing here is load-bearing: every target is one command you could type by
# hand. The point is that "did I break it?" is always `make` and never a question
# of remembering flags.

NIX ?= nix

# Run tools out of the nixpkgs this flake already pins, so the formatter and the
# code come from the same revision.
PINNED := $(NIX) run --inputs-from . nixpkgs\#

# gemset.nix is bundix's output, not ours — reformatting it would just be undone
# by the next `make gemset`.
NIX_FILES := $(filter-out gemset.nix,$(shell git ls-files '*.nix'))

.DEFAULT_GOAL := help
.PHONY: help all check test gemset fmt fmt-check clean

help: ## Show this help
	@echo 'mail2rss26 — targets:'
	@grep -hE '^[a-z][a-z-]*:.*?## ' $(MAKEFILE_LIST) \
		| sed 's/:.*## /\t/' \
		| awk -F'\t' '{ printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }'

all: check ## Everything that runs without a server — run this before every commit

# --- Tests ------------------------------------------------------------------

check: ## Evaluate the flake and run every check (the Minitest suite; later the nixosTest)
	$(NIX) flake check

# The fast loop. Same interpreter and same gems as `make check`, without the
# copy into the store — this is the one to run while writing code.
test: ## Run the Minitest suite in the dev shell
	$(NIX) develop -c ruby -Ilib -Itest test/run.rb

# --- Gems -------------------------------------------------------------------
# Gemfile.lock and gemset.nix are generated, committed, and always regenerated
# together: a lock without a matching gemset is a build failure waiting for the
# next `nix flake check`.

gemset: ## Regenerate Gemfile.lock and gemset.nix after a Gemfile change
	$(NIX) develop -c bundle lock
	$(NIX) develop -c bundix

# --- Formatting -------------------------------------------------------------
# Not part of `check` on purpose: a failing `make check` should mean the code is
# broken, not that a brace moved.

fmt: ## Format all .nix files with nixfmt
	$(PINNED)nixfmt-rfc-style -- $(NIX_FILES)

fmt-check: ## Report unformatted .nix files without rewriting them
	$(PINNED)nixfmt-rfc-style -- --check $(NIX_FILES)

clean: ## Remove ./result symlinks (store paths stay until a gc)
	rm -f result result-*
