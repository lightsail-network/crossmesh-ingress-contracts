# `crossmesh-interfaces`

The types and cross-contract interfaces the contracts share: the factory configuration and the two bounds
fixed in code (the 10 % discount cap and the 900 s price-age cap), the oracle price types, and the client traits for the oracle, the filler, the factory, the vault and the Aquarius router.
Every contract depends on this crate and on nothing else in the workspace.
