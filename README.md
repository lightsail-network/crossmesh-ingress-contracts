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

Intentional patterns (governance-fixed rescue sink, `== 0` sentinel checks, trusted USDC/CCTP external
calls, hour-scale timestamp comparisons) are suppressed inline with `slither-disable` comments next to a
justification — new findings therefore always fail CI.

## License

MIT
