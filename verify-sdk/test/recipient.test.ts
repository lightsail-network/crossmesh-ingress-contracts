import { StrKey } from "@stellar/stellar-sdk";
import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { checkRecipient } from "../src/recipient.js";
import { CONTRACTS, InvalidRecipientError, isValidRecipient } from "../src/index.js";
import { encodeStrkey, randomAccount, randomContract, randomMuxedAccount } from "./helpers.js";

const ACCOUNT = "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK";
const MUXED_ACCOUNT = "MBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDUAAAAAAAAAAE2KX5I"; // ACCOUNT, id 1234
const CONTRACT = "CADQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQP5KR"; // contract ID 0x0707…07

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** The verdict of the installed @stellar/stellar-sdk, as an independent oracle for the copied code. */
function sdkValid(strkey: string): boolean {
  return StrKey.isValidEd25519PublicKey(strkey) || StrKey.isValidMed25519PublicKey(strkey) || StrKey.isValidContract(strkey);
}

/** The message {@link checkRecipient} refuses `input` with, or null if it accepts it. */
function rejection(input: unknown): string | null {
  try {
    checkRecipient(input);
    return null;
  } catch (error) {
    expect(error).toBeInstanceOf(InvalidRecipientError);
    expect((error as Error).name).toBe("InvalidRecipientError");
    return (error as Error).message;
  }
}

describe("isValidRecipient", () => {
  it("accepts G, M and C keys", () => {
    for (const key of [ACCOUNT, MUXED_ACCOUNT, CONTRACT]) expect(isValidRecipient(key), key).toBe(true);
  });

  it("agrees with stellar-sdk on random valid keys", () => {
    for (let i = 0; i < 300; i++) {
      for (const key of [randomAccount(), randomMuxedAccount(), randomContract()]) expect(isValidRecipient(key), key).toBe(sdkValid(key));
    }
  });

  it("agrees with stellar-sdk on single-character mutations", () => {
    let rejected = 0;
    for (let i = 0; i < 3000; i++) {
      const key = [randomAccount, randomMuxedAccount, randomContract][i % 3]!();
      const position = Math.floor(Math.random() * key.length);
      const mutated = key.slice(0, position) + BASE32_ALPHABET.charAt(Math.floor(Math.random() * 32)) + key.slice(position + 1);
      expect(isValidRecipient(mutated), mutated).toBe(sdkValid(mutated));
      if (!isValidRecipient(mutated)) rejected++;
    }
    expect(rejected).toBeGreaterThan(2500); // the mutations mostly break the checksum
  });

  it("accepts every valid contract: Circle's CctpForwarder and USDC contract, and our own VaultFactory", () => {
    for (const id of [
      "CBZL2IH7F6BIDAA3WBNXYKIXSATJGMSW7K5P5MJ6STX5RXN47TZJDF5T", // mainnet CctpForwarder
      "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75", // mainnet USDC
      "CA66Q2WFBND6V4UEB7RD4SAXSVIWMD6RA4X3U32ELVFGXV5PJK4T4VSZ", // testnet CctpForwarder
      "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", // testnet USDC
      CONTRACTS.testnet.vaultFactory!,
    ]) {
      expect(isValidRecipient(id), id).toBe(true);
    }
  });

  it("rejects non-strings", () => {
    for (const input of [undefined, null, 1, {}, Uint8Array.of(1)]) expect(isValidRecipient(input)).toBe(false);
  });

  it("rejects strkey types other than G, M and C", () => {
    for (const key of [
      "",
      ACCOUNT.toLowerCase(),
      StrKey.encodeEd25519SecretSeed(randomBytes(32)),
      StrKey.encodePreAuthTx(randomBytes(32)),
      StrKey.encodeSha256Hash(randomBytes(32)),
      StrKey.encodeLiquidityPool(randomBytes(32)),
    ]) {
      expect(isValidRecipient(key), key).toBe(false);
    }
  });

  it("rejects a muxed key with a non-zero padding bit (non-canonical encoding)", () => {
    // 69 chars carry 345 bits for 344 data bits: the last character's low bit is padding
    const lastSymbol = BASE32_ALPHABET.indexOf(MUXED_ACCOUNT.charAt(68));
    expect(lastSymbol & 1).toBe(0);
    const nonCanonical = MUXED_ACCOUNT.slice(0, 68) + BASE32_ALPHABET.charAt(lastSymbol | 1);
    expect(isValidRecipient(nonCanonical)).toBe(false);
    expect(sdkValid(nonCanonical)).toBe(false);
  });

  it("never throws", () => {
    for (let i = 0; i < 2000; i++) {
      const input = Buffer.from(randomBytes(Math.floor(Math.random() * 80))).toString("latin1");
      expect(() => isValidRecipient(input)).not.toThrow();
    }
    expect(() => isValidRecipient(`G${"A".repeat(1_000_000)}`)).not.toThrow();
  });
});

describe("checkRecipient", () => {
  it("accepts what isValidRecipient accepts", () => {
    for (const key of [ACCOUNT, MUXED_ACCOUNT, CONTRACT]) expect(rejection(key)).toBeNull();
  });

  it("says why it refuses: not a string, not a G, M or C address, or the decoder's reason", () => {
    const cases: [unknown, RegExp][] = [
      [undefined, /recipient must be a string/],
      [42, /recipient must be a string/],
      ["", /recipient must be a Stellar G, M or C address/],
      [StrKey.encodeEd25519SecretSeed(randomBytes(32)), /recipient must be a Stellar G, M or C address/],
      [ACCOUNT.slice(0, 55), /invalid encoded string length: expected 56, got 55/],
      [`${ACCOUNT} `, /invalid encoded string length/],
      [MUXED_ACCOUNT + "A", /invalid encoded string length: expected 69, got 70/],
      [ACCOUNT.slice(0, 20) + "0" + ACCOUNT.slice(21), /invalid character in base32 input/],
      ["G" + ACCOUNT.slice(1).toLowerCase(), /invalid character in base32 input/],
      [ACCOUNT.slice(0, 55) + (ACCOUNT.charAt(55) === "A" ? "B" : "A"), /invalid checksum/],
      [encodeStrkey((6 << 3) | 1, randomBytes(32)), /invalid version byte/], // 'G' prefix, low bits set
      [encodeStrkey(6 << 3, randomBytes(40)), /invalid encoded string length/], // 69-char G
    ];
    for (const [input, message] of cases) {
      expect(rejection(input), String(input)).toMatch(message);
      if (typeof input === "string") expect(sdkValid(input), input).toBe(false);
    }
  });
});
