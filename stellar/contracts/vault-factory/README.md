# `vault-factory`

One per network. Holds the configuration (tokens, oracle, vault code hash, discount), deploys each
user's vault at an address derived from the user's Stellar address, and keeps the list of relayers that
may trigger swaps. It is the only contract allowed to call a vault's `swap`.

The admin can only add or remove relayers and move the discount within the 10 % cap fixed in code. Nothing else
can change; a different configuration means a new factory.

Details: the doc comments in `src/lib.rs`; design in `../../docs/DESIGN.md` §5.1.
