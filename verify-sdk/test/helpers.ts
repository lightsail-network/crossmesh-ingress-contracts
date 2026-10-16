import { Keypair, StrKey } from "@stellar/stellar-sdk";
import { randomBytes } from "node:crypto";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** Test-side strkey encoder for arbitrary version bytes (stellar-sdk only encodes the named ones). */
export function encodeStrkey(version: number, payload: Uint8Array): string {
  const body = Uint8Array.of(version, ...payload);
  let crc = 0;
  for (const byte of body) {
    crc ^= byte << 8;
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  const data = Uint8Array.of(...body, crc & 0xff, crc >> 8);
  let out = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of data) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += ALPHABET.charAt((buffer >> bits) & 31);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out += ALPHABET.charAt((buffer << (5 - bits)) & 31);
  return out;
}

export function randomAccount(): string {
  return Keypair.random().publicKey();
}

export function randomMuxedAccount(): string {
  return StrKey.encodeMed25519PublicKey(randomBytes(40));
}

export function randomContract(): string {
  return StrKey.encodeContract(randomBytes(32));
}

export function randomRecipient(): string {
  return [randomAccount, randomMuxedAccount, randomContract][Math.floor(Math.random() * 3)]!();
}

export function randomIndex(): bigint {
  // mostly small (as issued), sometimes up to the full uint256 range
  return Math.random() < 0.7 ? BigInt(Math.floor(Math.random() * 1000)) : BigInt("0x" + randomBytes(32).toString("hex"));
}
