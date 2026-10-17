// Deployed contract addresses, hardcoded on purpose: re-deriving a deposit address is a cross-check
// against whoever handed it out, so the factory and implementation must not come from that same party
// (e.g. an API response). The contracts are immutable and deployed via CreateX with chain-independent
// init code (script/DeployCwia.s.sol), so each network's pair is the same on every EVM chain it serves.

export type Network = "mainnet" | "testnet";

export interface Deployment {
  /** DepositFactory — the CREATE2 deployer of every deposit address. */
  factory: `0x${string}`;
  /** DepositForwarder implementation every clone delegates to (`DepositFactory.implementation()`). */
  implementation: `0x${string}`;
}

// Frozen so no other code in the process can repoint them.
export const DEPLOYMENTS: Readonly<Record<Network, Readonly<Deployment> | null>> = Object.freeze({
  // → Stellar mainnet. Chains: deployments/README.md in the repository.
  mainnet: Object.freeze({
    factory: "0x8E6Ada2CFF0D86F5baFa575D11529FbFb50702e4",
    implementation: "0xa49eFd75214749ce8d0f6d838a7a44A90E2A9A45",
  }),
  // → Stellar testnet. Chains: deployments/README.md in the repository.
  testnet: Object.freeze({
    factory: "0xAD93f57DeA4F6bE812c0e1790dF5D3d1161BEd09",
    implementation: "0xb0216D95AFf228EB8b3A53C58f780D115eFfEC0F",
  }),
});

/** Stellar contract IDs that must never be a recipient: the CctpForwarder itself and the USDC contract. */
export const RESERVED_CONTRACTS: Readonly<Record<Network, readonly string[]>> = Object.freeze({
  mainnet: Object.freeze([
    "CBZL2IH7F6BIDAA3WBNXYKIXSATJGMSW7K5P5MJ6STX5RXN47TZJDF5T", // CctpForwarder
    "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75", // USDC
  ]),
  testnet: Object.freeze([
    "CA66Q2WFBND6V4UEB7RD4SAXSVIWMD6RA4X3U32ELVFGXV5PJK4T4VSZ", // CctpForwarder
    "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", // USDC
  ]),
});
