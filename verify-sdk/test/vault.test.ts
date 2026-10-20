import { Address, Networks, StrKey, hash, xdr } from "@stellar/stellar-sdk";
import { describe, expect, it } from "vitest";
import { PASSPHRASES, deriveVaultAddress } from "../src/vault.js";
import { CONTRACTS, InvalidRecipientError, computeDepositAddress, computeVaultAddress, verifyDepositAddress } from "../src/index.js";
import { randomContract, randomRecipient } from "./helpers.js";

/** Independent oracle: the installed @stellar/stellar-sdk building the same HashIdPreimage. */
function sdkVault(factory: string, recipient: string, passphrase: string): string {
  const preimage = xdr.HashIdPreimage.envelopeTypeContractId(
    new xdr.HashIdPreimageContractId({
      networkId: hash(Buffer.from(passphrase)),
      contractIdPreimage: xdr.ContractIdPreimage.contractIdPreimageFromAddress(
        new xdr.ContractIdPreimageFromAddress({
          address: Address.fromString(factory).toScAddress(),
          salt: hash(Buffer.from(recipient, "ascii")),
        }),
      ),
    }),
  );
  return StrKey.encodeContract(hash(preimage.toXDR()));
}

// Shared with the Rust factory test `vault_address_matches_the_javascript_test_vector`. Random factory and
// recipient, not a deployment.
const VECTOR_FACTORY = "CDBJUCCWJKJEFTFHFO5CKDTNYOSBFHT62WWY3HRYZRK766OERGMIGZY3";
const VECTOR_RECIPIENT = "GDU64RNQMOBNNXUED7NN4G2NY3F6RXRYOT4MJD2EBOM7FSUQIODFSV4T";
const VECTOR_TESTNET = "CCLJZGOHFH55O22RL2SLJPQC7JRLZV7DFYHKILFADQBWL2HBGT6G25J5";
const VECTOR_MAINNET = "CCQ4I5EWZUXRJLBUWLL44UDFUQQTFPTYLOFWFIQ4BMXMJSBA5NQ2D2MW";

// VaultFactories on Stellar testnet and recipient → vault pairs read back from the chain with `vault_address`.
// The first is the pinned testnet factory (stellar-v0.1.0-rc.1); the others are throwaway factories
// (2026-10-17/18) whose vaults were really deployed, matching the `Deployed` events.
const LIVE_VAULTS: [string, string, string][] = [
  // factory, recipient, vault
  [
    "CAOMURKNIBKRFVIGWLC7BQZTURTSSQQYS6V3PS65NZZRDRPFOKULT7V7",
    "GDU64RNQMOBNNXUED7NN4G2NY3F6RXRYOT4MJD2EBOM7FSUQIODFSV4T",
    "CDZCBMSZDDWSTHHRYGOXSF7M36VA3IE3JGKMKRMFYYN5UULE2WYTKUAK",
  ],
  [
    // The 2026-10-18 end-to-end run: this vault received 2.5 USDC from Circle and paid 77.66 XLM to its recipient.
    "CDQ5KJTXH7FIXLBJV7DGQZULXB3PKGVUFJ4BVNSSYTBCEHZIJZRFBTI6",
    "GD2FUT7LI2AISNBOJXGAVFFQMTE7YZABY2VVK3LRS6OECGGLYRGMU4KU",
    "CBC653PQRAPJEOM5YRLQ35OILII7UYKLSEGHS3C3PYUALFIM6AOWPZ5O",
  ],
  [
    "CCNV3GXM55LKWJ34P34YHJ6NUM623ANKKXADX6AZZSNM76XZZOLW4KBQ",
    "GDDPUCQXLM6SCTKODQXJPBBFC6CE7O3Y6GQIQPTWXBNZU4ILRUJICIBW",
    "CCOIPVUXJSVYSBPIGXRYWR46KXZF734ENADUHS5LPG33LNFQY3B52GMA",
  ],
  [
    "CCNV3GXM55LKWJ34P34YHJ6NUM623ANKKXADX6AZZSNM76XZZOLW4KBQ",
    "GCCKJIUA4IJRNAWM7JWZDZE75BGYRP74O257RMO5S3G2MAQ2JFAFDMGT",
    "CD5IPY76LELGG22YCIRFFCRNGYWHIXK7KAG5FN3W6TRZRUCZ6IAYKPP7",
  ],
  [
    "CCABKOIGRB4XXO76CFQE7PUQ3YSXXDZVIBRCEHKUU5BJU6YZEKQRD67A",
    "GCBJNHDZX7QZW662DQFXM2GJZMXZCC2VKVHLGKDW7DMNBZGCG5HH6QIC",
    "CCE3NBQPS2EO3QFZ5B7TG7JC6YXAYXA6CUPH7G75HZ3RI2YQZF7IV5AQ",
  ],
  [
    "CCABKOIGRB4XXO76CFQE7PUQ3YSXXDZVIBRCEHKUU5BJU6YZEKQRD67A",
    "GCOZRW6VYBRCCCUNR2DCGVOJZJJ623FVACR2KPOT6BXGO4RL27IBVXBI",
    "CCYEKUKIZU7632BHJFCOJ5EC22CKJOY77CRQVXY6KFYKRKQVJA23PF25",
  ],
];

const NETWORKS = ["mainnet", "testnet"] as const;

describe("deriveVaultAddress", () => {
  it("matches the design-doc vector on both networks", () => {
    expect(deriveVaultAddress(VECTOR_FACTORY, VECTOR_RECIPIENT, Networks.TESTNET)).toBe(VECTOR_TESTNET);
    expect(deriveVaultAddress(VECTOR_FACTORY, VECTOR_RECIPIENT, Networks.PUBLIC)).toBe(VECTOR_MAINNET);
  });

  it.each(LIVE_VAULTS)("reproduces the vault testnet factory %s derives for %s", (factory, recipient, vault) => {
    expect(deriveVaultAddress(factory, recipient, Networks.TESTNET)).toBe(vault);
  });

  it("matches the stellar-sdk oracle on random recipients and factories", () => {
    for (let i = 0; i < 500; i++) {
      const factory = randomContract();
      const recipient = randomRecipient();
      for (const passphrase of [Networks.PUBLIC, Networks.TESTNET]) {
        expect(deriveVaultAddress(factory, recipient, passphrase)).toBe(sdkVault(factory, recipient, passphrase));
      }
    }
  });

  it("is network-, recipient- and factory-specific", () => {
    const vault = deriveVaultAddress(VECTOR_FACTORY, VECTOR_RECIPIENT, Networks.TESTNET);
    expect(deriveVaultAddress(VECTOR_FACTORY, VECTOR_RECIPIENT, Networks.PUBLIC)).not.toBe(vault);
    expect(deriveVaultAddress(VECTOR_FACTORY, randomRecipient(), Networks.TESTNET)).not.toBe(vault);
    expect(deriveVaultAddress(randomContract(), VECTOR_RECIPIENT, Networks.TESTNET)).not.toBe(vault);
  });
});

describe("network constants", () => {
  it("hold the network passphrases and a valid VaultFactory or none", () => {
    expect(PASSPHRASES).toEqual({ mainnet: Networks.PUBLIC, testnet: Networks.TESTNET });
    expect(Object.isFrozen(PASSPHRASES)).toBe(true);
    for (const network of NETWORKS) {
      const factory = CONTRACTS[network].vaultFactory;
      if (factory !== null) expect(StrKey.isValidContract(factory), network).toBe(true);
    }
  });
});

describe("computeVaultAddress", () => {
  for (const network of NETWORKS) {
    const factory = CONTRACTS[network].vaultFactory;

    it.skipIf(factory === null)(`derives the vault from the pinned ${network} VaultFactory`, () => {
      for (const recipient of [VECTOR_RECIPIENT, randomRecipient(), randomRecipient()]) {
        expect(computeVaultAddress({ recipient, network }), recipient).toBe(sdkVault(factory!, recipient, PASSPHRASES[network]));
      }
      expect(() => computeVaultAddress({ recipient: "GNOTANADDRESS", network })).toThrow(InvalidRecipientError);
    });

    it.skipIf(factory !== null)(`throws on ${network} while no VaultFactory is pinned`, () => {
      expect(() => computeVaultAddress({ recipient: VECTOR_RECIPIENT, network })).toThrow(/no VaultFactory/);
    });
  }

  it("throws TypeError for params or a network it does not know", () => {
    expect(() => computeVaultAddress(undefined as never)).toThrow(TypeError);
    expect(() => computeVaultAddress({ recipient: VECTOR_RECIPIENT, network: "devnet" as never })).toThrow(TypeError);
  });
});

describe("XLM delivery", () => {
  it("matches the testnet vector, checked against VaultFactory.vault_address and DepositFactory.computeAddress on Sepolia and Amoy", () => {
    expect(computeVaultAddress({ recipient: VECTOR_RECIPIENT, network: "testnet" })).toBe("CDZCBMSZDDWSTHHRYGOXSF7M36VA3IE3JGKMKRMFYYN5UULE2WYTKUAK");
    const params = { recipient: VECTOR_RECIPIENT, deliveryAsset: "XLM", speed: "standard", index: 0, network: "testnet" } as const;
    expect(computeDepositAddress(params)).toBe("0xeFAFc5597da04345f49cA6D3d8921e1F63bEae66");
  });

  for (const network of NETWORKS) {
    const factory = CONTRACTS[network].vaultFactory;

    it.skipIf(factory === null)(`commits the recipient's vault on ${network}`, () => {
      const recipient = randomRecipient();
      const vault = computeVaultAddress({ recipient, network });
      for (const speed of ["standard", "fast"] as const) {
        const xlm = computeDepositAddress({ recipient, deliveryAsset: "XLM", speed, index: 5, network });
        expect(xlm).toBe(computeDepositAddress({ recipient: vault, deliveryAsset: "USDC", speed, index: 5, network }));
        expect(xlm).not.toBe(computeDepositAddress({ recipient, deliveryAsset: "USDC", speed, index: 5, network }));
      }
    });

    it.skipIf(factory === null)(`verifies an XLM address on ${network} only as one`, () => {
      const params = { recipient: VECTOR_RECIPIENT, deliveryAsset: "XLM", speed: "standard", index: 0, network } as const;
      const depositAddress = computeDepositAddress(params);
      expect(verifyDepositAddress({ ...params, depositAddress })).toBe(true);
      expect(verifyDepositAddress({ ...params, deliveryAsset: "USDC", depositAddress })).toBe(false);
    });

    it.skipIf(factory !== null)(`is unavailable on ${network} while no VaultFactory is pinned`, () => {
      const params = { recipient: VECTOR_RECIPIENT, deliveryAsset: "XLM", speed: "standard", index: 0, network } as const;
      expect(() => computeDepositAddress(params)).toThrow(/no VaultFactory/);
      // The testnet vector's address, which cannot be checked without a VaultFactory.
      expect(verifyDepositAddress({ ...params, depositAddress: "0xeFAFc5597da04345f49cA6D3d8921e1F63bEae66" })).toBe(false);
      // USDC delivery is unaffected.
      expect(computeDepositAddress({ ...params, deliveryAsset: "USDC" })).toMatch(/^0x[0-9a-fA-F]{40}$/);
    });
  }
});
