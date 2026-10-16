import { StrKey } from "@stellar/stellar-sdk";
import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { RESERVED_CONTRACTS, validateRecipient } from "../src/index.js";
import { encodeStrkey, randomAccount, randomContract, randomMuxedAccount } from "./helpers.js";

const ACCOUNT = "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK";
const MUXED_ACCOUNT = "MBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDUAAAAAAAAAAE2KX5I"; // ACCOUNT, id 1234
const CONTRACT = "CADQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQP5KR"; // contract ID 0x0707…07

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** The verdict of the installed @stellar/stellar-sdk, as an independent oracle for the copied code. */
function sdkVerdict(strkey: string): string | null {
  if (StrKey.isValidEd25519PublicKey(strkey)) return "account";
  if (StrKey.isValidMed25519PublicKey(strkey)) return "muxed_account";
  if (StrKey.isValidContract(strkey)) return "contract";
  return null;
}

/** The verdict of this package, in the same shape as {@link sdkVerdict}. */
function ourVerdict(strkey: string): string | null {
  const result = validateRecipient(strkey, "mainnet");
  return result.valid ? result.type : null;
}

function reason(input: unknown, network: "mainnet" | "testnet" = "mainnet"): string | undefined {
  const result = validateRecipient(input, network);
  return result.valid ? undefined : result.reason;
}

describe("validateRecipient", () => {
  it("accepts G, M and C keys", () => {
    expect(validateRecipient(ACCOUNT, "mainnet")).toEqual({ valid: true, type: "account" });
    expect(validateRecipient(MUXED_ACCOUNT, "mainnet")).toEqual({ valid: true, type: "muxed_account" });
    expect(validateRecipient(CONTRACT, "mainnet")).toEqual({ valid: true, type: "contract" });
  });

  it("agrees with stellar-sdk on random valid keys", () => {
    for (let i = 0; i < 300; i++) {
      for (const key of [randomAccount(), randomMuxedAccount(), randomContract()]) expect(ourVerdict(key)).toBe(sdkVerdict(key));
    }
  });

  it("agrees with stellar-sdk on single-character mutations", () => {
    let rejected = 0;
    for (let i = 0; i < 3000; i++) {
      const key = [randomAccount, randomMuxedAccount, randomContract][i % 3]!();
      const position = Math.floor(Math.random() * key.length);
      const mutated = key.slice(0, position) + BASE32_ALPHABET.charAt(Math.floor(Math.random() * 32)) + key.slice(position + 1);
      expect(ourVerdict(mutated), mutated).toBe(sdkVerdict(mutated));
      if (ourVerdict(mutated) === null) rejected++;
    }
    expect(rejected).toBeGreaterThan(2500); // the mutations mostly break the checksum
  });

  it("rejects non-strings", () => {
    for (const input of [undefined, null, 1, {}, Uint8Array.of(1)]) expect(reason(input)).toBe("not_a_string");
  });

  it("rejects strkey types other than G, M and C", () => {
    expect(reason("")).toBe("unsupported_type");
    expect(reason(ACCOUNT.toLowerCase())).toBe("unsupported_type");
    for (const key of [
      StrKey.encodeEd25519SecretSeed(randomBytes(32)),
      StrKey.encodePreAuthTx(randomBytes(32)),
      StrKey.encodeSha256Hash(randomBytes(32)),
      StrKey.encodeLiquidityPool(randomBytes(32)),
    ]) {
      expect(reason(key)).toBe("unsupported_type");
    }
  });

  it("rejects malformed G, M and C keys with the decoder's message", () => {
    const cases: [string, RegExp][] = [
      [ACCOUNT.slice(0, 55), /invalid encoded string length: expected 56, got 55/],
      [`${ACCOUNT} `, /invalid encoded string length/],
      [MUXED_ACCOUNT + "A", /invalid encoded string length: expected 69, got 70/],
      [ACCOUNT.slice(0, 20) + "0" + ACCOUNT.slice(21), /invalid character in base32 input/],
      ["G" + ACCOUNT.slice(1).toLowerCase(), /invalid character in base32 input/],
      [ACCOUNT.slice(0, 55) + (ACCOUNT.charAt(55) === "A" ? "B" : "A"), /invalid checksum/],
      [encodeStrkey((6 << 3) | 1, randomBytes(32)), /invalid version byte/], // 'G' prefix, low bits set
      [encodeStrkey(6 << 3, randomBytes(40)), /invalid encoded string length/], // 69-char G
    ];
    for (const [strkey, message] of cases) {
      const result = validateRecipient(strkey, "mainnet");
      expect(result, strkey).toMatchObject({ valid: false, reason: "invalid_strkey" });
      expect(result.valid ? "" : result.message, strkey).toMatch(message);
      expect(sdkVerdict(strkey), strkey).toBeNull();
    }
  });

  it("rejects a muxed key with a non-zero padding bit (non-canonical encoding)", () => {
    // 69 chars carry 345 bits for 344 data bits: the last character's low bit is padding
    const lastSymbol = BASE32_ALPHABET.indexOf(MUXED_ACCOUNT.charAt(68));
    expect(lastSymbol & 1).toBe(0);
    const nonCanonical = MUXED_ACCOUNT.slice(0, 68) + BASE32_ALPHABET.charAt(lastSymbol | 1);
    expect(reason(nonCanonical)).toBe("invalid_strkey");
    expect(sdkVerdict(nonCanonical)).toBeNull();
  });

  it("rejects the network's CctpForwarder and USDC contract IDs", () => {
    for (const network of ["mainnet", "testnet"] as const) {
      expect(RESERVED_CONTRACTS[network]).toHaveLength(2);
      for (const id of RESERVED_CONTRACTS[network]) {
        expect(StrKey.isValidContract(id)).toBe(true);
        expect(reason(id, network)).toBe("reserved_contract");
      }
    }
    // the other network's IDs are ordinary contract keys
    for (const id of RESERVED_CONTRACTS.testnet) expect(validateRecipient(id, "mainnet")).toEqual({ valid: true, type: "contract" });
  });

  it("never throws", () => {
    for (let i = 0; i < 2000; i++) {
      const input = Buffer.from(randomBytes(Math.floor(Math.random() * 80))).toString("latin1");
      expect(() => validateRecipient(input, "testnet")).not.toThrow();
    }
    expect(() => validateRecipient(`G${"A".repeat(1_000_000)}`, "testnet")).not.toThrow();
  });
});
