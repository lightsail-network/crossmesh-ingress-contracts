# Cross Mesh Ingress Verify SDK

Offline derivation of Cross Mesh Ingress deposit addresses, and validation of the Stellar recipient they
commit to. No RPC, no API call: the address is a pure function of the recipient, the index and the
immutable contracts, so an integrator can check every address it is handed before showing it to a user.

```sh
npm install @lightsail-network/crossmesh-ingress-verify-sdk
```

## Usage

Cross-check an address returned by `POST /deposit-addresses`:

```ts
import { verifyDepositAddress } from "@lightsail-network/crossmesh-ingress-verify-sdk";

const res = await createDepositAddress(recipient); // { deposit_address, recipient, index, ... }
const ok = verifyDepositAddress({
  depositAddress: res.deposit_address,
  recipient: res.recipient,
  index: res.index,
  network: "mainnet",
});
if (!ok || res.recipient !== recipient) throw new Error("deposit address does not match the recipient");
```

Derive an address directly, or validate a recipient on its own:

```ts
import { computeDepositAddress, validateRecipient } from "@lightsail-network/crossmesh-ingress-verify-sdk";

computeDepositAddress({ recipient: "G…", index: 0, network: "mainnet" }); // "0x…" (EIP-55)

validateRecipient("G…", "mainnet"); // { valid: true, type: "account" } | { valid: false, reason, message }
```

| Function | Returns | Throws |
| --- | --- | --- |
| `validateRecipient(recipient, network)` | `{ valid: true, type }` or `{ valid: false, reason, message }` | never |
| `computeDepositAddress({ recipient, index, fast?, network })` | EIP-55 address | `InvalidRecipientError`, `RangeError` (index), `TypeError` (non-boolean `fast`) |
| `verifyDepositAddress({ depositAddress, recipient, index, fast?, network })` | `boolean` (address compared case-insensitively) | as above |

`fast` defaults to `false` (standard CCTP transfer).

## What is checked

A recipient must be a `G` (account), `M` (muxed account) or `C` (contract) strkey that passes
js-stellar-sdk's own strkey validation: exact length, strict base32 with no padding and a canonical
encoding, the matching version byte and the CRC16-XMODEM checksum. A `C` recipient must also not be the
network's CctpForwarder or USDC contract. `reason` is `not_a_string`, `unsupported_type`,
`invalid_strkey` (with the decoder's `message`) or `reserved_contract`.

The contracts commit the recipient as-is, so an invalid recipient would still produce an address, and USDC
sent there could never be delivered. `computeDepositAddress` therefore refuses invalid recipients instead
of deriving an address for them.

The strkey code in `src/vendor/` is copied from
[js-stellar-sdk v17.2.1](https://github.com/stellar/js-stellar-sdk/tree/v17.2.1/src/base) and cut down to
these three types, so the package has no Stellar dependency. Its tests are copied alongside in
`test/vendor/`, and the package's own tests check every verdict against the real `@stellar/stellar-sdk`.
That code is Apache-2.0 (`LICENSE.stellar-sdk`); the rest of the package is MIT.

## Networks

`network: "mainnet"` is the deployment that delivers to Stellar mainnet, `"testnet"` the one that delivers to
Stellar testnet. The contract addresses and the EVM chains each network is deployed on are listed in
[deployments/README.md](https://github.com/lightsail-network/crossmesh-ingress-contracts/blob/main/deployments/README.md);
USDC sent on a chain that is not listed there is not delivered.

The contracts are immutable and deployed at the same addresses on every chain of a network, so a deposit
address is the same on all of them. The factory and implementation addresses are hardcoded in
`src/deployments.ts` on purpose: a cross-check must not take them from the same party that issued the deposit
address.

## Development

```sh
npm ci
npm run typecheck
npm test
ETHEREUM_RPC=https://ethereum-rpc.publicnode.com POLYGON_RPC=https://polygon-bor-rpc.publicnode.com BASE_RPC=https://base-rpc.publicnode.com \
  SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com AMOY_RPC=https://polygon-amoy-bor-rpc.publicnode.com \
  npm test # also checks against the deployed factories
```

## Releasing

Publishing a GitHub release tagged `verify-sdk-v<version>` (matching `package.json`) runs
`.github/workflows/verify-sdk-publish.yml`, which publishes to npm through trusted publishing (OIDC, with
provenance). A prerelease version (`1.1.0-beta.1`) is published under its prerelease dist-tag (`beta`), never
as `latest`.
