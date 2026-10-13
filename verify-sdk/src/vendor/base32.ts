/*
 * Not copied: a minimal stand-in for `fromBase32` / `toBase32` from @exodus/bytes, the only two functions
 * js-stellar-sdk's strkey.ts imports from it. RFC 4648 base32, no padding, strict decoding — the behaviour
 * js-stellar-sdk pins in test/unit/base/base32.test.ts (copied to test/vendor/base32.test.ts).
 */

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** Encode bytes as unpadded RFC 4648 base32. */
export function toBase32(bytes: Uint8Array): string {
  let out = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = ((buffer << 8) | byte) & 0xfff; // at most 12 live bits
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += ALPHABET.charAt((buffer >> bits) & 31);
    }
  }
  if (bits > 0) out += ALPHABET.charAt((buffer << (5 - bits)) & 31);
  return out;
}

/**
 * Decode unpadded RFC 4648 base32. Throws on any character outside the alphabet (including `=`), on a length
 * no byte string encodes to, and on non-zero trailing bits — so every accepted string is canonical.
 */
export function fromBase32(str: string): Uint8Array {
  if (str.includes("=")) throw new SyntaxError("base32 padding is not allowed");
  // 8 chars = 5 bytes; a final group of 1, 3 or 6 chars cannot come from whole bytes
  if ([1, 3, 6].includes(str.length % 8)) throw new SyntaxError("invalid base32 last chunk");
  const out = new Uint8Array(Math.floor((str.length * 5) / 8));
  let buffer = 0;
  let bits = 0;
  let o = 0;
  for (let i = 0; i < str.length; i++) {
    const v = ALPHABET.indexOf(str.charAt(i));
    if (v < 0) throw new SyntaxError("invalid character in base32 input");
    buffer = ((buffer << 5) | v) & 0xfff;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (buffer >> bits) & 0xff;
    }
  }
  if ((buffer & ((1 << bits) - 1)) !== 0) throw new SyntaxError("invalid base32 last chunk: non-zero trailing bits");
  return out;
}
