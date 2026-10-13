/*
 * Copied from js-stellar-sdk v17.2.1 (commit b4893496f69116d9db2a4a90214a7236831b6656):
 *   src/base/strkey.ts            https://github.com/stellar/js-stellar-sdk/blob/v17.2.1/src/base/strkey.ts
 *   src/base/util/checksum.ts     https://github.com/stellar/js-stellar-sdk/blob/v17.2.1/src/base/util/checksum.ts
 * Copyright 2015 Stellar Development Foundation. Licensed under the Apache License, Version 2.0
 * (see LICENSE.stellar-sdk in this package).
 *
 * Modified: only the decode/validate path for the three recipient types is kept.
 *   - Version bytes, length ranges and the decoded-length switch are cut down to G (ed25519PublicKey),
 *     M (med25519PublicKey) and C (contract). Every other type, all encode functions, the signed-payload
 *     and claimable-balance checks, and getVersionByteForPrefix are removed.
 *   - `fromBase32` / `toBase32` from @exodus/bytes are replaced by ./base32.ts and `concatUint8Arrays`
 *     from uint8array-extras is no longer needed, so this file has no dependencies.
 *   - `fromBase32(encoded, { padding: false })` becomes `fromBase32(encoded)`: ./base32.ts never accepts padding.
 *   - `verifyChecksum` (util/checksum.ts) is inlined below `calculateChecksum`.
 *   - `encoded[0]` gains a non-null assertion for this package's `noUncheckedIndexedAccess`.
 * Everything else — the order of checks, the canonical re-encoding check, the CRC table — is unchanged.
 */

/* eslint no-bitwise: ["error", {"allow": ["<<", ">>", "^", "&", "&="]}] */

import { fromBase32, toBase32 } from "./base32.js";

export type VersionByteName = "contract" | "ed25519PublicKey" | "med25519PublicKey";

const versionBytes: Record<VersionByteName, number> = {
  ed25519PublicKey: 6 << 3, // G (when encoded in base32)
  med25519PublicKey: 12 << 3, // M
  contract: 2 << 3, // C
};

export const strkeyTypes: Record<string, VersionByteName> = {
  G: "ed25519PublicKey",
  M: "med25519PublicKey",
  C: "contract",
};

function hasVersionByteName(
  versionByteName: string,
): versionByteName is VersionByteName {
  return Object.prototype.hasOwnProperty.call(versionBytes, versionByteName);
}

/** Legal encoded (strkey string) length range for a strkey type. */
function encodedLengthRange(name: VersionByteName): [number, number] {
  switch (name) {
    case "ed25519PublicKey":
    case "contract":
      return [56, 56];
    case "med25519PublicKey":
      return [69, 69];
  }
}

/**
 * The checks that can be made before decoding anything: is this a strkey type
 * we know, and is `encoded` a legal length for it?
 */
function hasValidStrkeyFormat(
  versionByteName: string,
  encoded: string,
): versionByteName is VersionByteName {
  if (!hasVersionByteName(versionByteName)) {
    return false;
  }

  const [minLen, maxLen] = encodedLengthRange(versionByteName);
  return encoded.length >= minLen && encoded.length <= maxLen;
}

/**
 * Explains a {@link hasValidStrkeyFormat} rejection. Only ever called on the
 * failure path, so it can afford to re-run the checks to find out which one
 * failed.
 */
function strkeyFormatError(versionByteName: string, encoded: string): Error {
  if (!hasVersionByteName(versionByteName)) {
    return new Error(
      `${versionByteName} is not a valid version byte name. ` +
        `Expected one of ${Object.keys(versionBytes).join(", ")}`,
    );
  }

  const [minLen, maxLen] = encodedLengthRange(versionByteName);
  return new Error(
    `invalid encoded string length: expected ` +
      `${minLen === maxLen ? minLen : `${minLen}-${maxLen}`}, ` +
      `got ${encoded.length}`,
  );
}

/**
 * StrKey is a helper class that allows decoding Stellar keys from their
 * string (i.e. "GABCD...", etc.) representations.
 */
export class StrKey {
  static types = strkeyTypes;

  /**
   * Decodes strkey ed25519 public key to raw data.
   *
   * @param data - "G..." key representation to decode
   */
  static decodeEd25519PublicKey(data: string): Uint8Array {
    return decodeCheck("ed25519PublicKey", data);
  }

  /**
   * Returns true if the given Stellar public key is a valid ed25519 public key.
   *
   * @param publicKey - public key to check
   */
  static isValidEd25519PublicKey(publicKey: string): boolean {
    return isValid("ed25519PublicKey", publicKey);
  }

  /**
   * Decodes strkey med25519 public key to raw data.
   *
   * @param address - data to decode
   */
  static decodeMed25519PublicKey(address: string): Uint8Array {
    return decodeCheck("med25519PublicKey", address);
  }

  /**
   * Returns true if the given Stellar public key is a valid med25519 public key.
   *
   * @param publicKey - public key to check
   */
  static isValidMed25519PublicKey(publicKey: string): boolean {
    return isValid("med25519PublicKey", publicKey);
  }

  /**
   * Decodes strkey contract (C...) to raw data.
   *
   * @param address - address to decode
   */
  static decodeContract(address: string): Uint8Array {
    return decodeCheck("contract", address);
  }

  /**
   * Checks validity of alleged contract (C...) strkey address.
   *
   * @param address - signer key to check
   */
  static isValidContract(address: string): boolean {
    return isValid("contract", address);
  }
}

/**
 * Sanity-checks whether or not a strkey *appears* valid.
 *
 * This isn't a *definitive* check of validity, but rather a best-effort
 * check based on (a) input length, (b) whether or not it can be decoded,
 * and (c) output length.
 *
 * @param versionByteName - the type of strkey to expect in `encoded`
 * @param encoded - the strkey to validate
 */
export function isValid(versionByteName: string, encoded: unknown): boolean {
  if (typeof encoded !== "string") {
    return false;
  }

  // Screen out the mismatches that don't need decoding before entering the
  // `try`, so the common negative case never pays for a thrown `Error`.
  if (!hasValidStrkeyFormat(versionByteName, encoded)) {
    return false;
  }
  // The prefix determines the version byte, which `decodeCheck` would reject
  // after decoding anyway.
  if (strkeyTypes[encoded[0]!] !== versionByteName) {
    return false;
  }

  let decoded: Uint8Array;
  try {
    decoded = decodeCheck(versionByteName, encoded);
  } catch {
    return false;
  }

  // basic length checks on the resulting buffer sizes
  switch (versionByteName) {
    case "ed25519PublicKey": // falls through
    case "contract":
      return decoded.length === 32;

    case "med25519PublicKey":
      return decoded.length === 40; // +8 bytes for the ID

    default:
      return false;
  }
}

/**
 * Decodes and validates a strkey-encoded string, verifying the version byte
 * and checksum.
 *
 * @param versionByteName - the expected strkey type
 * @param encoded - the strkey-encoded string to decode
 */
export function decodeCheck(
  versionByteName: string,
  encoded: string,
): Uint8Array {
  if (typeof encoded !== "string") {
    throw new TypeError("encoded argument must be of type String");
  }

  if (!hasValidStrkeyFormat(versionByteName, encoded)) {
    throw strkeyFormatError(versionByteName, encoded);
  }

  const decoded = fromBase32(encoded);
  const versionByte = decoded[0];
  const payload = decoded.slice(0, -2);
  const data = payload.slice(1);
  const checksum = decoded.slice(-2);

  if (encoded !== toBase32(decoded)) {
    throw new Error("invalid encoded string");
  }

  const expectedVersion = versionBytes[versionByteName];

  if (versionByte !== expectedVersion) {
    throw new Error(
      `invalid version byte. expected ${expectedVersion}, got ${versionByte}`,
    );
  }

  const expectedChecksum = calculateChecksum(payload);

  if (!verifyChecksum(expectedChecksum, checksum)) {
    throw new Error(`invalid checksum`);
  }

  return data;
}

// Computes the CRC16-XModem checksum of `payload` in little-endian order
function calculateChecksum(payload: Uint8Array): Uint8Array {
  const crcTable = [
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7, 0x8108,
    0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef, 0x1231, 0x0210,
    0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6, 0x9339, 0x8318, 0xb37b,
    0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de, 0x2462, 0x3443, 0x0420, 0x1401,
    0x64e6, 0x74c7, 0x44a4, 0x5485, 0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee,
    0xf5cf, 0xc5ac, 0xd58d, 0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6,
    0x5695, 0x46b4, 0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d,
    0xc7bc, 0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b, 0x5af5,
    0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12, 0xdbfd, 0xcbdc,
    0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a, 0x6ca6, 0x7c87, 0x4ce4,
    0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41, 0xedae, 0xfd8f, 0xcdec, 0xddcd,
    0xad2a, 0xbd0b, 0x8d68, 0x9d49, 0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13,
    0x2e32, 0x1e51, 0x0e70, 0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a,
    0x9f59, 0x8f78, 0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e,
    0xe16f, 0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e, 0x02b1,
    0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256, 0xb5ea, 0xa5cb,
    0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d, 0x34e2, 0x24c3, 0x14a0,
    0x0481, 0x7466, 0x6447, 0x5424, 0x4405, 0xa7db, 0xb7fa, 0x8799, 0x97b8,
    0xe75f, 0xf77e, 0xc71d, 0xd73c, 0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657,
    0x7676, 0x4615, 0x5634, 0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9,
    0xb98a, 0xa9ab, 0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882,
    0x28a3, 0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
    0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92, 0xfd2e,
    0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9, 0x7c26, 0x6c07,
    0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1, 0xef1f, 0xff3e, 0xcf5d,
    0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8, 0x6e17, 0x7e36, 0x4e55, 0x5e74,
    0x2e93, 0x3eb2, 0x0ed1, 0x1ef0,
  ];

  let crc16 = 0x0;

  for (let i = 0; i < payload.length; i += 1) {
    const byte = payload[i];
    if (byte === undefined) {
      continue;
    }

    const lookupIndex = (crc16 >> 8) ^ byte;
    crc16 = (crc16 << 8) ^ (crcTable[lookupIndex] ?? 0);
    crc16 &= 0xffff;
  }
  const checksum = new Uint8Array(2);
  checksum[0] = crc16 & 0xff;
  checksum[1] = (crc16 >> 8) & 0xff;
  return checksum;
}

/**
 * Returns true if the two byte arrays are equal (used for CRC16 checksum verification).
 *
 * @param expected - the expected checksum bytes
 * @param actual - the actual checksum bytes
 */
export function verifyChecksum(
  expected: Uint8Array,
  actual: Uint8Array,
): boolean {
  if (expected.length !== actual.length) {
    return false;
  }

  if (expected.length === 0) {
    return true;
  }

  for (let i = 0; i < expected.length; i += 1) {
    if (expected[i] !== actual[i]) {
      return false;
    }
  }

  return true;
}
