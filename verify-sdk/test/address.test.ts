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
import { CONTRACTS, InvalidRecipientError, computeDepositAddress, verifyDepositAddress } from "../src/index.js";
import { randomAccount, randomIndex, randomRecipient } from "./helpers.js";

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
  const VECTOR_CONTRACTS = {
    factory: "0x0E37Ba881cD1D6fAe4E26BC1a7C0D44A6Fbc028C",
    forwarderImplementation: "0x0c7DEaE2DF6b9dC3993c11b62e6BDD6A308CA80e",
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
    expect(deriveAddress(VECTOR_CONTRACTS, ascii(recipient), index, fast)).toBe(expected);
  });

  it("matches the viem oracle on random inputs, EIP-55 included", () => {
    const contracts = CONTRACTS.testnet;
    for (let i = 0; i < 1000; i++) {
      const recipient = randomRecipient();
      const index = randomIndex();
      const fast = Math.random() < 0.5;
      const derived = deriveAddress(contracts, ascii(recipient), index, fast);
      expect(derived).toBe(viemAddress(contracts.factory, contracts.forwarderImplementation, recipient, index, fast));
      expect(derived).toBe(getAddress(derived));
    }
  });
});

describe("computeDepositAddress", () => {
  const recipient = "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK";
  const params = { recipient, deliveryAsset: "USDC", speed: "standard", index: 0, network: "testnet" } as const;

  it("reproduces the live testnet clone (Sepolia + Polygon Amoy)", () => {
    expect(computeDepositAddress(params)).toBe("0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b963");
  });

  // The API reference's test vectors (crossmesh-ingress src/api/docs.ts), locked there against each network's
  // on-chain factory.computeAddress.
  it.each([
    ["mainnet", "standard", "0x0CDf8087a6F9709B85F87Cd6893c082AA89bA3d0"],
    ["mainnet", "fast", "0x4f6851dCB766872f60cF1Cf11851AaAe8d4B894a"],
    ["testnet", "standard", "0x93845A25A3a5F9b15c25532797CE56fD4851Fcce"],
    ["testnet", "fast", "0x36b10Bac9dfb4C10947dCd49cB480594F0a1124B"],
  ] as const)("matches the API reference's %s vector at %s speed", (network, speed, expected) => {
    const vector = { recipient: "GBRAD6AQVETCVZDBT3TLU3KXGPQIXOIQX5DLJYKHNZ4ZF6AWYQXEZGQD", deliveryAsset: "USDC", speed, index: 0, network } as const;
    expect(computeDepositAddress(vector)).toBe(expected);
  });

  it("derives a different address at each speed", () => {
    const random = { ...params, recipient: randomRecipient(), index: 3 };
    expect(computeDepositAddress({ ...random, speed: "fast" })).not.toBe(computeDepositAddress({ ...random, speed: "standard" }));
  });

  it("accepts number and bigint indices alike", () => {
    expect(computeDepositAddress({ ...params, index: 42 })).toBe(computeDepositAddress({ ...params, index: 42n }));
    expect(() => computeDepositAddress({ ...params, index: (1n << 256n) - 1n })).not.toThrow();
  });

  it("accepts any valid recipient, Circle's CctpForwarder and USDC contract included", () => {
    const circle = [
      "CBZL2IH7F6BIDAA3WBNXYKIXSATJGMSW7K5P5MJ6STX5RXN47TZJDF5T", // mainnet CctpForwarder
      "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75", // mainnet USDC
      "CA66Q2WFBND6V4UEB7RD4SAXSVIWMD6RA4X3U32ELVFGXV5PJK4T4VSZ", // testnet CctpForwarder
      "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", // testnet USDC
    ];
    for (const id of circle) {
      for (const network of ["mainnet", "testnet"] as const) {
        expect(computeDepositAddress({ ...params, recipient: id, network })).toMatch(/^0x[0-9a-fA-F]{40}$/);
      }
    }
  });

  it("throws InvalidRecipientError for an invalid recipient", () => {
    for (const bad of ["GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KA", "gbcq", "", 42, undefined]) {
      expect(() => computeDepositAddress({ ...params, recipient: bad as string }), String(bad)).toThrow(InvalidRecipientError);
    }
  });

  it("throws TypeError for params, a network, a delivery asset or a speed it does not know", () => {
    for (const bad of [undefined, null, recipient, 0]) {
      expect(() => computeDepositAddress(bad as never), String(bad)).toThrow(TypeError);
    }
    for (const network of ["Mainnet", "devnet", "", "toString", "constructor", undefined, null, 1]) {
      expect(() => computeDepositAddress({ ...params, network: network as never }), String(network)).toThrow(TypeError);
    }
    for (const deliveryAsset of ["usdc", "xlm", "EURC", "", undefined, null]) {
      expect(() => computeDepositAddress({ ...params, deliveryAsset: deliveryAsset as never }), String(deliveryAsset)).toThrow(TypeError);
    }
    // A missing speed or a look-alike must not select an address.
    for (const speed of [undefined, "FAST", "Standard", "true", true, false, 1, 0, null]) {
      expect(() => computeDepositAddress({ ...params, speed: speed as never }), String(speed)).toThrow(TypeError);
    }
  });

  it("throws RangeError for an index out of range, TypeError for one that is not a number", () => {
    for (const index of [-1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1, -1n, 1n << 256n]) {
      expect(() => computeDepositAddress({ ...params, index }), String(index)).toThrow(RangeError);
    }
    for (const index of ["0", undefined, null]) {
      expect(() => computeDepositAddress({ ...params, index: index as never }), String(index)).toThrow(TypeError);
    }
  });

  it("contract constants are frozen", () => {
    expect(() => {
      (CONTRACTS.testnet as { factory: string }).factory = "0x0000000000000000000000000000000000000000";
    }).toThrow(TypeError);
    expect(() => {
      (CONTRACTS as Record<string, unknown>).testnet = null;
    }).toThrow(TypeError);
  });
});

describe("verifyDepositAddress", () => {
  const params = {
    depositAddress: "0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b963",
    recipient: "GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK",
    deliveryAsset: "USDC",
    speed: "standard",
    index: 0,
    network: "testnet",
  } as const;

  it("accepts the right address in any case", () => {
    const hex = params.depositAddress.slice(2);
    for (const depositAddress of [params.depositAddress, `0x${hex.toLowerCase()}`, `0x${hex.toUpperCase()}`]) {
      expect(verifyDepositAddress({ ...params, depositAddress })).toBe(true);
    }
  });

  it("rejects a mismatch in recipient, delivery asset, speed, index, network or address", () => {
    expect(verifyDepositAddress({ ...params, recipient: randomAccount() })).toBe(false);
    expect(verifyDepositAddress({ ...params, deliveryAsset: "XLM" })).toBe(false);
    expect(verifyDepositAddress({ ...params, speed: "fast" })).toBe(false);
    expect(verifyDepositAddress({ ...params, index: 1 })).toBe(false);
    expect(verifyDepositAddress({ ...params, network: "mainnet" })).toBe(false);
    for (const depositAddress of ["0xDB35Ea4999BD7CFe838Fd71902Ad5F685460b964", "DB35Ea4999BD7CFe838Fd71902Ad5F685460b963", `${params.depositAddress}00`, ""]) {
      expect(verifyDepositAddress({ ...params, depositAddress }), depositAddress).toBe(false);
    }
  });

  it("an address bound to another recipient verifies only against that recipient", () => {
    const other = randomAccount();
    const depositAddress = computeDepositAddress({ ...params, recipient: other });
    expect(verifyDepositAddress({ ...params, recipient: other, depositAddress })).toBe(true);
    expect(verifyDepositAddress({ ...params, depositAddress })).toBe(false);
  });

  it("never throws", () => {
    const junk: unknown[] = [
      undefined,
      null,
      0,
      "",
      {},
      [],
      { ...params, depositAddress: 1 },
      { ...params, recipient: "G" },
      { ...params, deliveryAsset: "EURC" },
      { ...params, speed: "FAST" },
      { ...params, speed: undefined },
      { ...params, index: -1 },
      { ...params, network: "devnet" },
      { ...params, deliveryAsset: "XLM", network: "mainnet" },
    ];
    for (const input of junk) {
      expect(() => verifyDepositAddress(input as never)).not.toThrow();
      expect(verifyDepositAddress(input as never)).toBe(false);
    }
  });
});
