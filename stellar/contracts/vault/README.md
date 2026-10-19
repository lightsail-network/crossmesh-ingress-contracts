# `vault`

One per user, deployed by `vault-factory` at an address derived from the user's Stellar address. It is
the Stellar recipient committed in an XLM-mode deposit address: Circle's forwarder delivers the USDC
here, and the vault turns it into XLM for its owner, creating the owner's account if it does not exist.

Funds have two exits only. `swap` (callable by the factory alone, bounded by an oracle price floor)
sends everything to the owner as XLM; `withdraw` (owner-only) returns the USDC unchanged. The vault
stores nothing: its address is its identity.

Details: the doc comments in `src/lib.rs`; design in `../../docs/DESIGN.md` §5.2.
