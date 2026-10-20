// The contracts every address is derived from, hardcoded on purpose: re-deriving a deposit address is a
// cross-check against whoever handed it out, so they must not come from that same party (e.g. an API
// response). The EVM contracts are immutable and deployed via CreateX with chain-independent init code
// (script/DeployCwia.s.sol), so each network's set is the same on every EVM chain it serves; it is the set the
// API publishes as `contracts` in GET /v1/chains.

export type Network = "mainnet" | "testnet";

export interface Contracts {
  /** Config: each chain's fees, their caps and the operator. Not part of any address; pinned to read them on-chain. */
  config: `0x${string}`;
  /** DepositForwarder implementation every deposit address delegates to (`DepositFactory.implementation()`). */
  forwarderImplementation: `0x${string}`;
  /** DepositFactory — the CREATE2 deployer of every deposit address. */
  factory: `0x${string}`;
  /** Stellar VaultFactory (C address) — the deployer of every XLM-delivery vault; `null` until deployed. */
  vaultFactory: string | null;
}

// Frozen so no other code in the process can repoint them.
export const CONTRACTS: Readonly<Record<Network, Readonly<Contracts>>> = Object.freeze({
  // → Stellar mainnet. Chains: deployments/README.md in the repository.
  mainnet: Object.freeze({
    config: "0xcB9014b9AC3Fc9BC8516F3B75464703dba30234c",
    forwarderImplementation: "0xa49eFd75214749ce8d0f6d838a7a44A90E2A9A45",
    factory: "0x8E6Ada2CFF0D86F5baFa575D11529FbFb50702e4",
    vaultFactory: null,
  }),
  // → Stellar testnet. Chains: deployments/README.md in the repository.
  testnet: Object.freeze({
    config: "0xac4a1A66F69820289A879F5D5D57828BF92cDa26",
    forwarderImplementation: "0xb0216D95AFf228EB8b3A53C58f780D115eFfEC0F",
    factory: "0xAD93f57DeA4F6bE812c0e1790dF5D3d1161BEd09",
    vaultFactory: "CAOMURKNIBKRFVIGWLC7BQZTURTSSQQYS6V3PS65NZZRDRPFOKULT7V7", // stellar-v0.1.0-rc.1
  }),
});

/**
 * @internal The contracts of `network`.
 * @throws TypeError for anything but a {@link Network}.
 */
export function contractsFor(network: Network): Readonly<Contracts> {
  // Own keys only: CONTRACTS["toString"] would otherwise be a function, not "unknown network".
  if (typeof network !== "string" || !Object.hasOwn(CONTRACTS, network)) {
    throw new TypeError(`unknown network "${String(network)}": expected "mainnet" or "testnet"`);
  }
  return CONTRACTS[network];
}
