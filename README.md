# Cross Mesh Ingress — Contracts

**Trustless (non-custodial) EVM → Stellar USDC deposit forwarder.** Each deposit address is a CREATE2
contract whose only fund-moving action is to bridge its USDC, via [Circle CCTP](https://www.circle.com/cctp),
to a Stellar recipient committed inside the address itself — no key or admin can divert the principal, and
if the operator goes offline depositors can recover their own funds.

## Build & test

```sh
git submodule update --init --recursive # fresh clone (or `forge install`)
forge build
forge fmt --check
forge test # unit tests
FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract Fork # real CCTP on an Ethereum fork
```

## Static analysis

```sh
pipx install slither-analyzer==0.11.5 # match the CI pin
slither . # scope in slither.config.json (src/ only); expected finding count is zero
```

Intentional patterns are suppressed inline, each `slither-disable` comment sitting next to a
`// Slither <detector>: <why safe>` justification — new findings therefore always fail CI. The suppressed
set: the sweep timelock's timestamp compare and its `== 0` armed/spent sentinels, reentrancy shapes whose
external calls go only to trusted USDC / Circle CCTP contracts, the native-coin send to the
governance-fixed rescue sink, zero-as-revoke governance setters (`setFactory`, `transferOwnership`), and
an in-place assembly length tweak when reading the clone's immutable args.

## License

MIT
