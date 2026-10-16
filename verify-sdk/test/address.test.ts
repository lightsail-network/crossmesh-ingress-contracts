import {
  type Address,
  type Hex,
  encodeAbiParameters,
  encodePacked,
  getAddress,
  getCreate2Address,
  keccak256,
  stringToHex,
} from "viem";
import { describe, expect, it } from "vitest";
import { deriveAddress } from "../src/address.js";
import {
  DEPLOYMENTS,
  InvalidRecipientError,
  RESERVED_CONTRACTS,
  computeDepositAddress,
  verifyDepositAddress,
} from "../src/index.js";
import { randomIndex, randomRecipient } from "./helpers.js";

const ascii = (text: string) => Uint8Array.from(text, (char) => char.charCodeAt(0));

/** Independent oracle: the backend's viem implementation (crossmesh-ingress src/evm/cwia.ts). */
function viemAddress(factory: Address, implementation: Address, recipient: string, index: bigint, fast: boolean): Address {
  const recipientBytes = stringToHex(recipient);
  const args = encodePacked(["bytes", "uint8"], [recipientBytes, fast ? 1 : 0]);
  const salt = keccak256(encodeAbiParameters([{ type: "bytes" }, { type: "uint256" }], [recipientBytes, index]));
  const initCode: Hex = encodePacked(
    ["bytes1", "uint16", "bytes17", "address", "bytes15", "bytes"],
    ["0x61", (args.length - 2) / 2 + 0x2d, "0x3d81600a3d39f3363d3d373d3d3d363d73", implementation, "0x5af43d82803e903d91602b57fd5bf3", args],
  );
  return getCreate2Address({ from: factory, salt, bytecodeHash: keccak256(initCode) });
}

describe("deriveAddress", () => {
  // test/CwiaVector.t.sol — checked there against OZ Clones.predictDeterministicAddressWithImmutableArgs
  const VECTOR_DEPLOYMENT = {
    factory: "0x0E37Ba881cD1D6fAe4E26BC1a7C0D44A6Fbc028C",
    implementation: "0x0c7DEaE2DF6b9dC3993c11b62e6BDD6A308CA80e",
  } as const;
  const VECTOR_ACCOUNT = "GBUKBCG5VLRKAVYAIREJRUJHOKLIADZJOICRW43WVJCLES52BDOTCQZU";
  const VECTOR_CONTRACT = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXG7WP3GVQ4MV23U6AKOJVPJ4"; // bad checksum: not a valid strkey, still a derivation vector
  const VECTOR_MUXED_ACCOUNT = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAAACJUQ"; // 70 chars: not a valid strkey, still a derivation vector
  const vectors: [string, bigint, boolean, string][] = [
    [VECTOR_ACCOUNT, 0n, false, "0x95454a3001af5FAcc60f439B6397491Fe7BDF30B"],
    [VECTOR_ACCOUNT, 0n, true, "0x07054eC2792c414878C1840106e9666810dDC10C"],
    [VECTOR_ACCOUNT, 7n, false, "0xD6746898AD8d72D5B49a7dfc78D657f1FE70db3A"],
    [VECTOR_CONTRACT, 1n, false, "0x3CD2e19C6F5344573B7Dc9F26792712Ff108FbFb"],
    [VECTOR_CONTRACT, 1n, true, "0xadE8e331683585294B6834C6B78Ec9ac69653756"],
    [VECTOR_MUXED_ACCOUNT, 0n, false, "0xb8476417d37244dB18B9A08a4B6379445eeFFeB2"],
    [VECTOR_MUXED_ACCOUNT, 0n, true, "0xA6d8ca9D2FF6b984Ea3DfbB245439624688F6917"],
  ];

  it.each(vectors)("matches the Solidity vector %s/%s/%s", (recipient, index, fast, expected) => {
    expect(deriveAddress(VECTOR_DEPLOYMENT, ascii(recipient), index, fast)).toBe(expected);
  });

  it("matches the viem oracle on random inputs, EIP-55 included", () => {
    for (let i = 0; i < 1000; i++) {
      const recipient = randomRecipient();
      const index = randomIndex();
      const fast = Math.random() < 0.5;
      const deployment = DEPLOYMENTS.testnet!;
      const derived = deriveAddress(deployment, ascii(recipient), index, fast);
      expect(derived).toBe(viemAddress(deployment.factory, deployment.implementation, recipient, index, fast));
      expect(derived).toBe(getAddress(derived));
    }
  });
});

describe("computeDepositAddress", () => {
  it("reproduces the live testnet clone (Sepolia + Polygon Amoy)", () => {
    const recipient = "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK";
    expect(computeDepositAddress({ recipient, index: 0, network: "testnet" })).toBe("0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b963");
  });

  it("defaults to standard; fast and standard differ", () => {
    const recipient = randomRecipient();
    const std = computeDepositAddress({ recipient, index: 3, network: "testnet" });
    expect(computeDepositAddress({ recipient, index: 3, fast: false, network: "testnet" })).toBe(std);
    expect(computeDepositAddress({ recipient, index: 3, fast: true, network: "testnet" })).not.toBe(std);
  });

  it("rejects a non-boolean fast", () => {
    const recipient = randomRecipient();
    for (const fast of ["false", "true", 0, 1, null]) {
      expect(() => computeDepositAddress({ recipient, index: 0, fast: fast as unknown as boolean, network: "testnet" })).toThrow(TypeError);
    }
  });

  it("accepts number and bigint indices alike", () => {
    const recipient = randomRecipient();
    expect(computeDepositAddress({ recipient, index: 42, network: "testnet" })).toBe(
      computeDepositAddress({ recipient, index: 42n, network: "testnet" }),
    );
    expect(() => computeDepositAddress({ recipient, index: (1n << 256n) - 1n, network: "testnet" })).not.toThrow();
  });

  it("rejects out-of-range indices", () => {
    const recipient = randomRecipient();
    for (const index of [-1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1, -1n, 1n << 256n]) {
      expect(() => computeDepositAddress({ recipient, index, network: "testnet" })).toThrow(RangeError);
    }
  });

  it("refuses an invalid recipient", () => {
    for (const recipient of ["GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KA", "gbcq", RESERVED_CONTRACTS.testnet[0]!]) {
      expect(() => computeDepositAddress({ recipient, index: 0, network: "testnet" })).toThrow(InvalidRecipientError);
    }
  });

  it("deployment constants are frozen", () => {
    expect(() => {
      (DEPLOYMENTS.testnet as { factory: string }).factory = "0x0000000000000000000000000000000000000000";
    }).toThrow(TypeError);
    expect(() => {
      (DEPLOYMENTS as Record<string, unknown>).testnet = null;
    }).toThrow(TypeError);
    expect(() => {
      (RESERVED_CONTRACTS.mainnet as string[]).pop();
    }).toThrow(TypeError);
  });
});

describe("verifyDepositAddress", () => {
  const recipient = "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK";
  const depositAddress = "0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b963";

  it("accepts the right address in any case", () => {
    for (const candidate of [depositAddress, depositAddress.toLowerCase(), "0x" + depositAddress.slice(2).toUpperCase()]) {
      expect(verifyDepositAddress({ depositAddress: candidate, recipient, index: 0, network: "testnet" })).toBe(true);
    }
  });

  it("rejects a mismatch in index, mode or address", () => {
    expect(verifyDepositAddress({ depositAddress, recipient, index: 1, network: "testnet" })).toBe(false);
    expect(verifyDepositAddress({ depositAddress, recipient, index: 0, fast: true, network: "testnet" })).toBe(false);
    for (const candidate of ["0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b964", "DB35Ea4999BD7CFe838Fd71902Ad5F685460b963", depositAddress + "00", ""]) {
      expect(verifyDepositAddress({ depositAddress: candidate, recipient, index: 0, network: "testnet" })).toBe(false);
    }
  });

  it("throws on an invalid recipient rather than answering", () => {
    expect(() => verifyDepositAddress({ depositAddress, recipient: recipient.slice(1), index: 0, network: "testnet" })).toThrow(
      InvalidRecipientError,
    );
  });
});
