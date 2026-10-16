/*
 * Copied from js-stellar-sdk v17.2.1 test/unit/base/base32.test.ts
 * (https://github.com/stellar/js-stellar-sdk/blob/v17.2.1/test/unit/base/base32.test.ts).
 * Copyright 2015 Stellar Development Foundation. Licensed under the Apache License, Version 2.0
 * (see LICENSE.stellar-sdk in this package).
 *
 * Modified: runs against src/vendor/base32.ts, this package's stand-in for @exodus/bytes, so `fromBase32`
 * takes no `{ padding: false }` option; uint8array-extras helpers are replaced by Buffer.
 */

import { describe, expect, it } from "vitest";
import { fromBase32, toBase32 } from "../../src/vendor/base32.js";

const hexToUint8Array = (hex: string) => new Uint8Array(Buffer.from(hex, "hex"));
const uint8ArrayToHex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");

// Pins the base32 behavior strkey encoding relies on: unpadded RFC 4648
// output, strict decoding, and plain Uint8Array results — all without a
// Buffer global.
describe("base32 (as used by strkey)", () => {
  // RFC 4648 test vectors, padding stripped.
  const vectors: [string, string][] = [
    ["", ""],
    ["66", "MY"], // "f"
    ["666f", "MZXQ"], // "fo"
    ["666f6f", "MZXW6"], // "foo"
    ["666f6f62", "MZXW6YQ"], // "foob"
    ["666f6f6261", "MZXW6YTB"], // "fooba"
    ["666f6f626172", "MZXW6YTBOI"], // "foobar"
  ];

  it("encodes RFC 4648 test vectors without padding", () => {
    for (const [hex, expected] of vectors) {
      expect(toBase32(hexToUint8Array(hex))).to.equal(expected);
    }
  });

  it("decodes RFC 4648 test vectors", () => {
    for (const [hex, encoded] of vectors) {
      expect(uint8ArrayToHex(fromBase32(encoded))).to.equal(hex);
    }
  });

  it("round-trips a full strkey payload", () => {
    const payload = hexToUint8Array(
      "303f0c34bf93ad0d9971d04ccc90f705511c838aad9734a4a2fb0d7a03fc7fe89abcde",
    );
    expect(fromBase32(toBase32(payload))).to.deep.equal(payload);
  });

  it("rejects padded input", () => {
    expect(() => fromBase32("MZXW6YQ=")).to.throw(/padding/i);
  });

  it("rejects characters outside the alphabet", () => {
    expect(() => fromBase32("MZXW6YT!")).to.throw(/invalid character/i);
    expect(() => fromBase32("G0AA")).to.throw(/invalid character/i);
  });

  it("rejects non-canonical trailing bits and truncated chunks", () => {
    // canonical form of "foobar" is MZXW6YTBOI; OJ has nonzero trailing bits
    expect(() => fromBase32("MZXW6YTBOJ")).to.throw(/last chunk/i);
    expect(() => fromBase32("GB")).to.throw(/last chunk/i);
  });

  it("returns Uint8Array, not Buffer", () => {
    const decoded = fromBase32("MZXW6YTBOI");
    expect(decoded).to.be.instanceOf(Uint8Array);
    expect(decoded.constructor).to.equal(Uint8Array);
  });
});
