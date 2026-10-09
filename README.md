# Cross Mesh Ingress — Contracts

**Trustless (non-custodial) EVM → Stellar USDC deposit forwarder.** Each deposit address is a CREATE2
contract whose only fund-moving action is to bridge its USDC, via [Circle CCTP](https://www.circle.com/cctp),
to a Stellar recipient committed inside the address itself — no key or admin can divert the principal, and
if the operator goes offline depositors can recover their own funds.

## Stellar-side delivery

A settlement burns USDC on the EVM chain and emits a CCTP message whose `hookData` frames the
committed Stellar recipient. Delivery on Stellar is a separate, permissionless step: someone fetches
Circle's attestation for the message and calls `mint_and_forward(message, attestation)` on Circle's
`CctpForwarder` (`CBZL2IH7F6BIDAA3WBNXYKIXSATJGMSW7K5P5MJ6STX5RXN47TZJDF5T` on mainnet), which mints
and forwards to the recipient in one non-custodial invocation. Cross Mesh — the service that runs the
operator and issues deposit addresses to integrators — runs a Stellar relayer that submits this
for every settlement it flushes. A depositor's self-rescue `sweep` is detected by the same service and
completed on the Stellar side manually today (automated relay of external sweeps is planned), but it
never has to wait for that: the call takes no authorization and the recipient comes from the message,
so anyone — including the depositor — can submit it from any funded Stellar account. Circle's
Forwarding Service does not serve Stellar, which is why the `hookData` magic field is zero (Circle's
prescribed value for `CctpForwarder`). See the threat model, DoS.1.R.3.

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

## License

MIT
