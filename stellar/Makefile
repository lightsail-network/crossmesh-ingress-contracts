# Stellar-side contracts (design: docs/DESIGN.md). Run from this directory.
.PHONY: build test fmt fmt-check lint clean all

all: fmt-check lint test build

# Wasm for every cdylib crate → target/wasm32v1-none/release/*.wasm (stellar-cli 28.1.0, as pinned in CI).
build:
	stellar contract build

test:
	cargo test

fmt:
	cargo fmt --all

fmt-check:
	cargo fmt --all -- --check

lint:
	cargo clippy --all-targets -- -D warnings

clean:
	cargo clean
