import { keccak_256 } from "@noble/hashes/sha3.js";
import { DEPLOYMENTS, type Deployment, type Network } from "./deployments.js";
import { InvalidRecipientError, validateRecipient } from "./strkey.js";

// Mirrors DepositFactory.computeAddress (OZ Clones.predictDeterministicAddressWithImmutableArgs):
//   args     = recipient ‖ uint8(fast)
//   salt     = keccak256(abi.encode(bytes recipient, uint256 index))
//   initCode = 0x61 ‖ uint16(args.length + 0x2d) ‖ 3d81600a3d39f3363d3d373d3d3d363d73 ‖ impl
//              ‖ 5af43d82803e903d91602b57fd5bf3 ‖ args
//   address  = keccak256(0xff ‖ factory ‖ salt ‖ keccak256(initCode))[12:]
// `recipient` is the strkey's UTF-8 (= ASCII) bytes.

export interface DepositAddressParams {
  /** Stellar recipient strkey (G, M or C). */
  recipient: string;
  /** Per-recipient index, 0 ≤ index < 2^256. */
  index: bigint | number;
  /** CCTP fast-transfer address instead of standard. Default false. */
  fast?: boolean;
  network: Network;
}

/**
 * The deposit address for `(recipient, index, fast)` on `network`, EIP-55 checksummed. Identical on every
 * EVM chain of the network; valid before the clone is deployed.
 * @throws InvalidRecipientError if the recipient fails {@link validateRecipient}.
 */
export function computeDepositAddress(params: DepositAddressParams): `0x${string}` {
  const check = validateRecipient(params.recipient, params.network);
  if (!check.valid) throw new InvalidRecipientError(check.reason, check.message);
  const deployment = DEPLOYMENTS[params.network];
  if (!deployment) throw new Error(`no ${params.network} deployment`);
  return deriveAddress(deployment, ascii(params.recipient), toIndex(params.index), toFast(params.fast));
}

/**
 * Whether `depositAddress` (any case) is the deposit address for `(recipient, index, fast)` on `network`.
 * @throws InvalidRecipientError if the recipient fails {@link validateRecipient}.
 */
export function verifyDepositAddress(params: DepositAddressParams & { depositAddress: string }): boolean {
  const expected = computeDepositAddress(params);
  return /^0x[0-9a-fA-F]{40}$/.test(params.depositAddress) && params.depositAddress.toLowerCase() === expected.toLowerCase();
}

/** @internal The raw derivation, without recipient validation. */
export function deriveAddress(deployment: Deployment, recipient: Uint8Array, index: bigint, fast: boolean): `0x${string}` {
  const args = concat(recipient, Uint8Array.of(fast ? 1 : 0));
  if (args.length > 0x5fd3) throw new Error("recipient too long"); // OZ CloneArgumentsTooLong
  const salt = keccak_256(abiEncodeBytesUint256(recipient, index));
  const initCode = concat(
    Uint8Array.of(0x61, (args.length + 0x2d) >> 8, (args.length + 0x2d) & 0xff),
    hexToBytes("3d81600a3d39f3363d3d373d3d3d363d73"),
    hexToBytes(deployment.implementation.slice(2)),
    hexToBytes("5af43d82803e903d91602b57fd5bf3"),
    args,
  );
  const hash = keccak_256(concat(Uint8Array.of(0xff), hexToBytes(deployment.factory.slice(2)), salt, keccak_256(initCode)));
  return toChecksumAddress(bytesToHex(hash.subarray(12)));
}

// A truthy non-boolean (e.g. the string "false") would otherwise silently select the fast address.
function toFast(fast: boolean | undefined): boolean {
  if (fast !== undefined && typeof fast !== "boolean") throw new TypeError("fast must be a boolean");
  return fast ?? false;
}

function toIndex(index: bigint | number): bigint {
  if (typeof index === "number") {
    if (!Number.isSafeInteger(index) || index < 0) throw new RangeError("index must be a non-negative safe integer");
    return BigInt(index);
  }
  if (typeof index !== "bigint" || index < 0n || index >= 1n << 256n) throw new RangeError("index must be a uint256");
  return index;
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

/** Bytes of an ASCII string (= its UTF-8 bytes; every valid strkey is ASCII). */
function ascii(text: string): Uint8Array {
  return Uint8Array.from(text, (char) => char.charCodeAt(0));
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  let hex = "";
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
  return hex;
}
