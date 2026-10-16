/*
 * Copied from js-stellar-sdk v17.2.1 test/unit/base/strkey.test.ts
 * (https://github.com/stellar/js-stellar-sdk/blob/v17.2.1/test/unit/base/strkey.test.ts).
 * Copyright 2015 Stellar Development Foundation. Licensed under the Apache License, Version 2.0
 * (see LICENSE.stellar-sdk in this package).
 *
 * Modified to match the trimmed src/vendor/strkey.ts:
 *   - Only cases about decoding/validating G, M and C keys are kept. Removed: everything about S, T, X, P,
 *     L and B keys as the type under test, encoding, signed payloads, liquidity pools, claimable
 *     balances, getVersionByteForPrefix and the muxed-account XDR helpers.
 *   - Keys a kept case needs to encode come from @stellar/stellar-sdk's StrKey (`SdkStrKey`), since the
 *     copy has no encode functions; uint8array-extras helpers are replaced by Buffer.
 *   - The muxed-ID cases check the decoded 40 bytes (key ‖ big-endian id) instead of going through XDR.
 *   - In "cross-type validation", the predicates are cut to the three kept; the samples still cover every type.
 *   - In "#invalidStrKeys" (SEP-23), only the G and M cases are kept.
 */

import { StrKey as SdkStrKey } from "@stellar/stellar-sdk";
import { beforeEach, describe, expect, it } from "vitest";
import { StrKey, decodeCheck } from "../../src/vendor/strkey.js";

const hexToUint8Array = (hex: string) => new Uint8Array(Buffer.from(hex, "hex"));
const uint8ArrayToHex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");

const PUBKEY = "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ";
const MPUBKEY =
  "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK";
const RAW_MPUBKEY = hexToUint8Array(
  "3f0c34bf93ad0d9971d04ccc90f705511c838aad9734a4a2fb0d7a03fc7fe89a8000000000000000",
);

describe("StrKey", () => {
  let unencodedBytes: Uint8Array;
  let accountIdEncoded: string;

  beforeEach(() => {
    unencodedBytes = StrKey.decodeEd25519PublicKey(PUBKEY);
    accountIdEncoded = PUBKEY;
  });

  describe("#decodeCheck", () => {
    it("decodes correctly", () => {
      expect(StrKey.decodeEd25519PublicKey(accountIdEncoded)).toEqual(
        unencodedBytes,
      );
    });

    it("throws an error when the version byte is wrong", () => {
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "SBGWKM3CD4IL47QN6X54N6Y33T3JDNVI6AIJ6CD5IM47HG3IG4O36XCU",
        ),
      ).toThrow(/invalid version/);
    });

    it("throws an error when decoded data encodes to other string", () => {
      // accountId
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "GBPXX0A5N4JYPESHAADMQKBPWZWQDQ64ZV6ZL2S3LAGW4SY7NTCMWIVL",
        ),
      ).toThrow(/invalid character in base32 input/i);
      expect(
        () =>
          StrKey.decodeEd25519PublicKey(
            "GCFZB6L25D26RQFDWSSBDEYQ32JHLRMTT44ZYE3DZQUTYOL7WY43PLBG++",
          ),
        // 58 chars: rejected by the encoded-length guard before base32 decode
      ).toThrow(/invalid encoded string length/i);
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "GADE5QJ2TY7S5ZB65Q43DFGWYWCPHIYDJ2326KZGAGBN7AE5UY6JVDRRA",
        ),
      ).toThrow(
        /invalid (encoded string|base32 length|last chunk|character in base32 input)/i,
      );
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "GB6OWYST45X57HCJY5XWOHDEBULB6XUROWPIKW77L5DSNANBEQGUPADT2",
        ),
      ).toThrow(
        /invalid (encoded string|base32 length|last chunk|character in base32 input)/i,
      );
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "GB6OWYST45X57HCJY5XWOHDEBULB6XUROWPIKW77L5DSNANBEQGUPADT2T",
        ),
      ).toThrow(
        /invalid (encoded string|base32 length|last chunk|character in base32 input)/i,
      );
    });

    it("throws an error when the checksum is wrong", () => {
      expect(() =>
        StrKey.decodeEd25519PublicKey(
          "GBPXXOA5N4JYPESHAADMQKBPWZWQDQ64ZV6ZL2S3LAGW4SY7NTCMWIVT",
        ),
      ).toThrow(/invalid checksum/);
    });
  });

  describe("#decodeCheck length bounds", () => {
    it("rejects an oversized G-shaped string before decoding", () => {
      const huge = `G${"A".repeat(1_000_000)}`;
      expect(() => StrKey.decodeEd25519PublicKey(huge)).toThrow(
        /invalid encoded string length: expected 56, got 1000001/,
      );
    });

    it("rejects a checksummed strkey with a wrong-sized payload", () => {
      // encodes fine (valid version byte + CRC16) but is not 32 bytes, so
      // decodeCheck must throw rather than return a 37-byte buffer
      const wrongSize = SdkStrKey.encodeEd25519PublicKey(new Uint8Array(37));
      expect(() => decodeCheck("ed25519PublicKey", wrongSize)).toThrow(
        /invalid encoded string length/,
      );
    });

    it("rejects unknown version byte names before decoding", () => {
      expect(() => decodeCheck("notAType", PUBKEY)).toThrow(
        /not a valid version byte name/,
      );
    });

    it("still decodes valid strkeys of every type (regression)", () => {
      expect(StrKey.decodeEd25519PublicKey(PUBKEY)).toHaveLength(32); // G
      expect(
        StrKey.decodeContract(
          "CA3D5KRYM6CB7OWQ6TWYRR3Z4T7GNZLKERYNZGGA5SOAOPIFY6YQGAXE",
        ),
      ).toHaveLength(32); // C

      // 69-char M
      expect(StrKey.decodeMed25519PublicKey(MPUBKEY)).toHaveLength(40);
    });
  });

  describe("#isValidEd25519PublicKey", () => {
    it("returns true for valid public key", () => {
      const keys = [
        "GBBM6BKZPEHWYO3E3YKREDPQXMS4VK35YLNU7NFBRI26RAN7GI5POFBB",
        "GB7KKHHVYLDIZEKYJPAJUOTBE5E3NJAXPSDZK7O6O44WR3EBRO5HRPVT",
        "GD6WVYRVID442Y4JVWFWKWCZKB45UGHJAABBJRS22TUSTWGJYXIUR7N2",
        "GBCG42WTVWPO4Q6OZCYI3D6ZSTFSJIXIS6INCIUF23L6VN3ADE4337AP",
        "GDFX463YPLCO2EY7NGFMI7SXWWDQAMASGYZXCG2LATOF3PP5NQIUKBPT",
        "GBXEODUMM3SJ3QSX2VYUWFU3NRP7BQRC2ERWS7E2LZXDJXL2N66ZQ5PT",
        "GAJHORKJKDDEPYCD6URDFODV7CVLJ5AAOJKR6PG2VQOLWFQOF3X7XLOG",
        "GACXQEAXYBEZLBMQ2XETOBRO4P66FZAJENDHOQRYPUIXZIIXLKMZEXBJ",
        "GDD3XRXU3G4DXHVRUDH7LJM4CD4PDZTVP4QHOO4Q6DELKXUATR657OZV",
        "GDTYVCTAUQVPKEDZIBWEJGKBQHB4UGGXI2SXXUEW7LXMD4B7MK37CWLJ",
      ];

      for (const key of keys) {
        expect(StrKey.isValidEd25519PublicKey(key)).toBe(true);
      }
    });

    it("returns false for invalid public key", () => {
      const keys: Array<string | null> = [
        "GBPXX0A5N4JYPESHAADMQKBPWZWQDQ64ZV6ZL2S3LAGW4SY7NTCMWIVL",
        "GCFZB6L25D26RQFDWSSBDEYQ32JHLRMTT44ZYE3DZQUTYOL7WY43PLBG++",
        "GADE5QJ2TY7S5ZB65Q43DFGWYWCPHIYDJ2326KZGAGBN7AE5UY6JVDRRA",
        "GB6OWYST45X57HCJY5XWOHDEBULB6XUROWPIKW77L5DSNANBEQGUPADT2",
        "GB6OWYST45X57HCJY5XWOHDEBULB6XUROWPIKW77L5DSNANBEQGUPADT2T",
        "GDXIIZTKTLVYCBHURXL2UPMTYXOVNI7BRAEFQCP6EZCY4JLKY4VKFNLT",
        "SAB5556L5AN5KSR5WF7UOEFDCIODEWEO7H2UR4S5R62DFTQOGLKOVZDY",
        "gWRYUerEKuz53tstxEuR3NCkiQDcV4wzFHmvLnZmj7PUqxW2wt",
        "test",
        null,
        "g4VPBPrHZkfE8CsjuG2S4yBQNd455UWmk", // Old network key
      ];

      for (const key of keys) {
        expect(StrKey.isValidEd25519PublicKey(key as unknown as string)).toBe(
          false,
        );
      }
    });
  });

  describe("#muxedAccounts", () => {
    it("decodes M... addresses correctly", () => {
      expect(StrKey.decodeMed25519PublicKey(MPUBKEY)).toEqual(RAW_MPUBKEY);
    });

    const cases = [
      {
        strkey:
          "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK",
        id: "9223372036854775808", // 0x8000...
      },
      {
        strkey:
          "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAFB4CJJBRKA",
        id: "1357924680",
      },
      {
        strkey:
          "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAE2JUG6",
        id: "1234",
      },
      {
        strkey:
          "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ",
        id: "0",
      },
    ];

    for (const testCase of cases) {
      it(`decodes muxed key w/ ID=${testCase.id}`, () => {
        expect(StrKey.isValidMed25519PublicKey(testCase.strkey)).toBe(true);
        const raw = StrKey.decodeMed25519PublicKey(testCase.strkey);
        expect(raw.subarray(0, 32)).toEqual(StrKey.decodeEd25519PublicKey(PUBKEY));
        expect(Buffer.from(raw.subarray(32)).readBigUInt64BE()).toBe(
          BigInt(testCase.id),
        );
      });
    }
  });

  describe("#contracts", () => {
    it("valid w/ 32-byte payload", () => {
      const strkey = "CA3D5KRYM6CB7OWQ6TWYRR3Z4T7GNZLKERYNZGGA5SOAOPIFY6YQGAXE";
      const decoded = StrKey.decodeContract(strkey);

      expect(uint8ArrayToHex(decoded)).toBe(
        "363eaa3867841fbad0f4ed88c779e4fe66e56a2470dc98c0ec9c073d05c7b103",
      );
    });

    it("isValid", () => {
      const valid = "CA3D5KRYM6CB7OWQ6TWYRR3Z4T7GNZLKERYNZGGA5SOAOPIFY6YQGAXE";
      expect(StrKey.isValidContract(valid)).toBe(true);

      const invalid =
        "GA3D5KRYM6CB7OWQ6TWYRR3Z4T7GNZLKERYNZGGA5SOAOPIFY6YQGAXE";
      expect(StrKey.isValidContract(invalid)).toBe(false);
    });
  });

  describe("#isValidMed25519PublicKey", () => {
    it("returns true for a valid M-address", () => {
      expect(
        StrKey.isValidMed25519PublicKey(
          "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK",
        ),
      ).toBe(true);
    });

    it("rejects invalid M-addresses", () => {
      expect(StrKey.isValidMed25519PublicKey("")).toBe(false);
      expect(StrKey.isValidMed25519PublicKey("MINVALID")).toBe(false);
      expect(
        StrKey.isValidMed25519PublicKey(
          "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ",
        ),
      ).toBe(false);
    });
  });

  describe("cross-type validation", () => {
    // every predicate accepts its own type and nothing else
    const seed32 = new Uint8Array(32).map((_, i) => i + 1);
    const seed40 = new Uint8Array(40).map((_, i) => i + 1);
    const seed33 = new Uint8Array(33).map((_, i) => (i === 0 ? 0 : i));

    const samples: Record<string, string> = {
      ed25519PublicKey: SdkStrKey.encodeEd25519PublicKey(seed32),
      ed25519SecretSeed: SdkStrKey.encodeEd25519SecretSeed(seed32),
      med25519PublicKey: SdkStrKey.encodeMed25519PublicKey(seed40),
      preAuthTx: SdkStrKey.encodePreAuthTx(seed32),
      sha256Hash: SdkStrKey.encodeSha256Hash(seed32),
      contract: SdkStrKey.encodeContract(seed32),
      liquidityPool: SdkStrKey.encodeLiquidityPool(seed32),
      claimableBalance: SdkStrKey.encodeClaimableBalance(seed33),
      signedPayload:
        "PA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAQACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IBZGM",
    };

    const predicates: Record<string, (value: string) => boolean> = {
      ed25519PublicKey: StrKey.isValidEd25519PublicKey,
      med25519PublicKey: StrKey.isValidMed25519PublicKey,
      contract: StrKey.isValidContract,
    };

    for (const [predicateName, isValid] of Object.entries(predicates)) {
      for (const [sampleName, strkey] of Object.entries(samples)) {
        const expected = predicateName === sampleName;
        it(`isValid${predicateName} on a ${sampleName} strkey is ${expected}`, () => {
          expect(isValid(strkey)).toBe(expected);
        });
      }
    }
  });

  describe("#invalidStrKeys", () => {
    // From https://stellar.org/protocol/sep-23#invalid-test-cases
    const badStrkeys: [string, string][] = [
      // The unused trailing bit must be zero in the encoding of the last three
      // bytes (24 bits) as five base-32 symbols (25 bits)
      ["med25519PublicKey", "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUR"],
      // Invalid length (congruent to 1 mod 8)
      ["ed25519PublicKey", "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZA"],
      // Invalid algorithm (low 3 bits of version byte are 7)
      ["ed25519PublicKey", "G47QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVP2I"],
      // Invalid length (congruent to 6 mod 8)
      ["med25519PublicKey", "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLKA"],
      // Invalid algorithm (low 3 bits of version byte are 7)
      ["med25519PublicKey", "M47QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ"],
      // Padding bytes are not allowed
      ["med25519PublicKey", "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUK==="],
      // Invalid checksum
      ["med25519PublicKey", "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUO"],
    ];

    for (const [versionByteName, address] of badStrkeys) {
      it(`fails in expected case ${address}`, () => {
        expect(() => decodeCheck(versionByteName, address)).toThrow();
      });
    }
  });
});
