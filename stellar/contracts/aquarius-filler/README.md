# `aquarius-filler`

The swap venue adapter. A vault hands it USDC and it returns XLM, swapping through the Aquarius AMM
router along a route the relayer passes in with each call. It serves vault code only, holds nothing
between calls and has no privileged functions; to change venues, the relayer points at another filler.

Details: the doc comments in `src/lib.rs`; design in `../../docs/DESIGN.md` §5.3.
