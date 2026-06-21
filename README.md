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

## License

MIT
