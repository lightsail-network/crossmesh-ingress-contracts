# Cross Mesh Ingress Verify SDK

Offline verification of the deposit addresses the Cross Mesh Ingress API hands out. No RPC, no API call: an
address is a pure function of its recipient, delivery asset, speed and index and of the immutable contracts, so
an integrator can check every address it is handed before showing it to a user.

```sh
npm install @lightsail-network/crossmesh-ingress-verify-sdk
```

## Usage

Cross-check an address returned by `POST /v1/deposit-addresses`:

```ts
import { verifyDepositAddress } from "@lightsail-network/crossmesh-ingress-verify-sdk";

const ok = verifyDepositAddress({
  depositAddress: res.deposit_address, // from the API
  index: res.index, // from the API
  recipient: user.stellarAddress, // your own record of the user, never res.recipient
  deliveryAsset: "USDC",
  speed: "fast",
  network: "mainnet",
});
if (!ok) throw new Error("deposit address failed verification");
```

Take `depositAddress` and `index` from the API and the rest from what you asked for: an address bound to someone
else's recipient verifies against that recipient, so checking it against `res.recipient` proves nothing.

Derive an address or a vault yourself, or validate a recipient:

```ts
import { computeDepositAddress, computeVaultAddress, isValidRecipient } from "@lightsail-network/crossmesh-ingress-verify-sdk";

computeDepositAddress({ recipient: "G…", deliveryAsset: "USDC", speed: "standard", index: 0, network: "mainnet" }); // "0x…" (EIP-55)
computeVaultAddress({ recipient: "G…", network: "testnet" }); // "C…", the recipient's vault (XLM delivery)
isValidRecipient("G…"); // true
```

| Function | Returns |
| --- | --- |
| `verifyDepositAddress({ depositAddress, recipient, deliveryAsset, speed, index, network })` | `boolean`; never throws |
| `computeDepositAddress({ recipient, deliveryAsset, speed, index, network })` | EIP-55 address |
| `computeVaultAddress({ recipient, network })` | `C` address |
| `isValidRecipient(recipient)` | `boolean`; never throws |

`deliveryAsset` is `"USDC"` or `"XLM"`, `speed` `"standard"` or `"fast"`, `index` a number or a
bigint and `network` `"mainnet"` or `"testnet"`. The compute functions throw `InvalidRecipientError` for a
recipient that is not a valid G, M or C address (`message` says why), `TypeError` for a missing or unknown
`network`, `deliveryAsset` or `speed`, `RangeError` for an `index` out of range, and `Error` for XLM delivery on a
network without a VaultFactory.

## XLM delivery

With `deliveryAsset: "XLM"` the recipient receives XLM instead of USDC, and the deposit address commits the
recipient's **vault** instead of the recipient: a Soroban contract that Cross Mesh's VaultFactory deploys at an
address derived from `(vaultFactory, sha256(recipient))`, where the USDC arrives before it is converted. The
derivation is pure hashing, so recipient → vault → deposit address is checked offline; `index` counts per vault.

The VaultFactory is deployed on testnet only so far: `CONTRACTS.mainnet.vaultFactory` is `null`, so on mainnet
the compute functions throw for XLM delivery and it never verifies. See `stellar/docs/DESIGN.md` §4 in the
repository for the normative rules.

## What is checked

A recipient must be a `G` (account), `M` (muxed account) or `C` (contract) strkey that passes js-stellar-sdk's
own strkey validation: exact length, strict base32 with no padding and a canonical encoding, the matching
version byte and the CRC16-XMODEM checksum. Any valid address is accepted, a contract included: which address
receives the funds is the user's decision, and a contract recipient must be able to use what it receives.

The contracts commit the recipient as-is, so an invalid recipient would still produce an address, and USDC
sent there could never be delivered. The compute functions therefore refuse invalid recipients instead of
deriving an address for them.

The strkey code in `src/vendor/` is copied from
[js-stellar-sdk v17.2.1](https://github.com/stellar/js-stellar-sdk/tree/v17.2.1/src/base) and cut down to
these three types, so the package has no Stellar dependency. Its tests are copied alongside in
`test/vendor/`, and the package's own tests check every verdict against the real `@stellar/stellar-sdk`.
That code is Apache-2.0 (`LICENSE.stellar-sdk`); the rest of the package is MIT.

## Contracts

`CONTRACTS[network]` holds the contract addresses: `config`, `forwarderImplementation` and `factory` (the set the
API publishes as `contracts` in `GET /v1/chains`), and `vaultFactory` (`null` until deployed). They are
hardcoded on purpose: a cross-check must not take them from the same party that issued the deposit address.

## Development

```sh
npm ci
npm run typecheck
npm test
ETHEREUM_RPC=https://ethereum-rpc.publicnode.com POLYGON_RPC=https://polygon-bor-rpc.publicnode.com BASE_RPC=https://base-rpc.publicnode.com \
  SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com AMOY_RPC=https://polygon-amoy-bor-rpc.publicnode.com \
  STELLAR_TESTNET_RPC=https://soroban-testnet.stellar.org \
  npm test # also checks against the deployed contracts
```

`STELLAR_MAINNET_RPC` runs the same `vault_address` check on mainnet once it has a VaultFactory.

## Releasing

Publishing a GitHub release tagged `verify-sdk-v<version>` (matching `package.json`) runs
`.github/workflows/verify-sdk-publish.yml`, which publishes to npm through trusted publishing (OIDC, with
provenance). A prerelease version (`2.0.0-dev.1`) is published under its prerelease dist-tag (`dev`), never
as `latest`.
