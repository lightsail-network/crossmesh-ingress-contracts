import { keccak_256 } from "@noble/hashes/sha3.js";
import { ascii, bytesToHex, concat, hexToBytes } from "./bytes.js";
import { contractsFor, type Contracts, type Network } from "./contracts.js";
import { checkRecipient } from "./recipient.js";
import { computeVaultAddress } from "./vault.js";

// Mirrors DepositFactory.computeAddress (OZ Clones.predictDeterministicAddressWithImmutableArgs):
//   args     = recipient ‖ uint8(fast)
//   salt     = keccak256(abi.encode(bytes recipient, uint256 index))
//   initCode = 0x61 ‖ uint16(args.length + 0x2d) ‖ 3d81600a3d39f3363d3d373d3d3d363d73 ‖ impl
//              ‖ 5af43d82803e903d91602b57fd5bf3 ‖ args
//   address  = keccak256(0xff ‖ factory ‖ salt ‖ keccak256(initCode))[12:]
// `recipient` is the UTF-8 (= ASCII) bytes of the strkey the address commits: the recipient itself with USDC
// delivery, its vault with XLM delivery. `fast` is `speed === "fast"`.

/** What the recipient receives. */
export type DeliveryAsset = "USDC" | "XLM";

/** The CCTP transfer speed of a deposit address. */
export type TransferSpeed = "standard" | "fast";

export interface DepositAddressParams {
  /** Stellar recipient: a G (account), M (muxed account) or C (contract) address. */
  recipient: string;
  deliveryAsset: DeliveryAsset;
  speed: TransferSpeed;
  /** Per-recipient index (per vault with XLM delivery), 0 ≤ index < 2^256. */
  index: number | bigint;
  network: Network;
}

/**
 * The deposit address for `params`, EIP-55 checksummed. Identical on every EVM chain of the network; valid before
 * anything is deployed.
 * @throws InvalidRecipientError if the recipient is not a valid G, M or C address.
 * @throws TypeError for an unknown network, delivery asset or speed; RangeError for an index out of range; Error
 *   for XLM delivery on a network without a VaultFactory.
 */
export function computeDepositAddress(params: DepositAddressParams): `0x${string}` {
  if (typeof params !== "object" || params === null) throw new TypeError("params must be an object");
  const { recipient, network } = params;
  const contracts = contractsFor(network);
  checkRecipient(recipient);
  const xlm = toXlm(params.deliveryAsset);
  const fast = toFast(params.speed);
  const index = toIndex(params.index);
  const committed = xlm ? computeVaultAddress({ recipient, network }) : recipient;
  return deriveAddress(contracts, ascii(committed), index, fast);
}

/**
 * Whether `depositAddress` (any case) is the deposit address for the other params. Take `depositAddress` and
 * `index` from the API and the rest from what you asked for — `recipient` from your own record of the user, never
 * from the response: an address bound to someone else verifies against that someone. Never throws: anything that
 * does not verify is `false`.
 */
export function verifyDepositAddress(params: DepositAddressParams & { depositAddress: string }): boolean {
  try {
    const { depositAddress } = params;
    if (typeof depositAddress !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(depositAddress)) return false;
    return depositAddress.toLowerCase() === computeDepositAddress(params).toLowerCase();
  } catch {
    return false;
  }
}

/** @internal The raw derivation, without validation. */
export function deriveAddress(
  contracts: Pick<Contracts, "factory" | "forwarderImplementation">,
  recipient: Uint8Array,
  index: bigint,
  fast: boolean,
): `0x${string}` {
  const args = concat(recipient, Uint8Array.of(fast ? 1 : 0));
  if (args.length > 0x5fd3) throw new Error("recipient too long"); // OZ CloneArgumentsTooLong
  const salt = keccak_256(abiEncodeBytesUint256(recipient, index));
  const initCode = concat(
    Uint8Array.of(0x61, (args.length + 0x2d) >> 8, (args.length + 0x2d) & 0xff),
    hexToBytes("3d81600a3d39f3363d3d373d3d3d363d73"),
    hexToBytes(contracts.forwarderImplementation.slice(2)),
    hexToBytes("5af43d82803e903d91602b57fd5bf3"),
    args,
  );
  const hash = keccak_256(concat(Uint8Array.of(0xff), hexToBytes(contracts.factory.slice(2)), salt, keccak_256(initCode)));
  return toChecksumAddress(bytesToHex(hash.subarray(12)));
}

function toXlm(deliveryAsset: DeliveryAsset): boolean {
  if (deliveryAsset === "USDC") return false;
  if (deliveryAsset === "XLM") return true;
  throw new TypeError('deliveryAsset must be "USDC" or "XLM"');
}

// Exact values only: a missing speed or a look-alike (e.g. "FAST" or true) would otherwise select an address.
function toFast(speed: TransferSpeed): boolean {
  if (speed === "standard") return false;
  if (speed === "fast") return true;
  throw new TypeError('speed must be "standard" or "fast"');
}

function toIndex(index: number | bigint): bigint {
  if (typeof index === "number") {
    if (Number.isSafeInteger(index) && index >= 0) return BigInt(index);
    throw new RangeError("index must be a non-negative safe integer");
  }
  if (typeof index !== "bigint") throw new TypeError("index must be a number or a bigint");
  if (index >= 0n && index < 1n << 256n) return index;
  throw new RangeError("index must be a uint256");
}

/** abi.encode(bytes data, uint256 value): offset(0x40) ‖ value ‖ len(data) ‖ data right-padded to 32 bytes. */
function abiEncodeBytesUint256(data: Uint8Array, value: bigint): Uint8Array {
  const padded = new Uint8Array(Math.ceil(data.length / 32) * 32);
  padded.set(data);
  return concat(uint256(0x40n), uint256(value), uint256(BigInt(data.length)), padded);
}

function uint256(value: bigint): Uint8Array {
  return hexToBytes(value.toString(16).padStart(64, "0"));
}

/** EIP-55 mixed-case checksum of a 40-char lowercase hex address (no 0x). */
function toChecksumAddress(hex: string): `0x${string}` {
  const hash = bytesToHex(keccak_256(ascii(hex)));
  let out = "0x";
  for (let i = 0; i < 40; i++) out += parseInt(hash.charAt(i), 16) >= 8 ? hex.charAt(i).toUpperCase() : hex.charAt(i);
  return out as `0x${string}`;
}
