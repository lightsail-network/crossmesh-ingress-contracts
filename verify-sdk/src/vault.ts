import { sha256 } from "@noble/hashes/sha2.js";
import { ascii } from "./bytes.js";
import { contractsFor, type Network } from "./contracts.js";
import { checkRecipient } from "./recipient.js";
import { deriveContractAddress } from "./soroban.js";

// XLM delivery (stellar/docs/DESIGN.md §4): the deposit address commits, as its Stellar recipient, the
// recipient's VAULT — a stateless Soroban contract that Cross Mesh's VaultFactory deploys at an address the
// protocol derives from (factory, sha256(recipient strkey)). The derivation is pure hashing, so recipient →
// vault → deposit address is checked entirely offline.

/** @internal Network passphrases: part of every contract-address preimage, so mainnet and testnet vaults differ. */
export const PASSPHRASES: Readonly<Record<Network, string>> = Object.freeze({
  mainnet: "Public Global Stellar Network ; September 2015",
  testnet: "Test SDF Network ; September 2015",
});

export interface VaultAddressParams {
  /** Stellar recipient: a G (account), M (muxed account) or C (contract) address. */
  recipient: string;
  network: Network;
}

/**
 * The vault (C address) of `recipient` on `network`: the Stellar recipient its XLM-delivery deposit addresses
 * commit, where their USDC arrives before it is converted. Identical whether or not the vault is deployed yet.
 * @throws InvalidRecipientError if the recipient is not a valid G, M or C address.
 * @throws TypeError for an unknown network; Error if the network has no VaultFactory.
 */
export function computeVaultAddress(params: VaultAddressParams): string {
  if (typeof params !== "object" || params === null) throw new TypeError("params must be an object");
  const { recipient, network } = params;
  const factory = contractsFor(network).vaultFactory;
  checkRecipient(recipient);
  if (factory === null) throw new Error(`XLM delivery: no VaultFactory on ${network} in this version of the SDK`);
  return deriveVaultAddress(factory, recipient, PASSPHRASES[network]);
}

/** @internal The raw derivation, without validation: `salt = sha256(ascii(recipient))`. */
export function deriveVaultAddress(factory: string, recipient: string, passphrase: string): string {
  return deriveContractAddress(factory, sha256(ascii(recipient)), passphrase);
}
