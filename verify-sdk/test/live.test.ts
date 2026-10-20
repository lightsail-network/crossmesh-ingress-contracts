import { Account, BASE_FEE, Contract, Keypair, TransactionBuilder, nativeToScVal, rpc, scValToNative } from "@stellar/stellar-sdk";
import { type Address, createPublicClient, http, parseAbi, stringToHex } from "viem";
import { describe, expect, it } from "vitest";
import { PASSPHRASES } from "../src/vault.js";
import { CONTRACTS, type DeliveryAsset, type Network, type TransferSpeed, computeDepositAddress, computeVaultAddress } from "../src/index.js";
import { randomAccount, randomContract, randomMuxedAccount } from "./helpers.js";

// Against the DEPLOYED contracts: every derivation must equal the chain's own — computeDepositAddress
// DepositFactory.computeAddress, computeVaultAddress VaultFactory.vault_address. Each RPC env var is optional;
// its suite is skipped when unset (and a Stellar suite while the network has no VaultFactory).
const EVM_CHAINS: { name: string; env: string; network: Network }[] = [
  { name: "Ethereum", env: "ETHEREUM_RPC", network: "mainnet" },
  { name: "Polygon PoS", env: "POLYGON_RPC", network: "mainnet" },
  { name: "Base", env: "BASE_RPC", network: "mainnet" },
  { name: "Ethereum Sepolia", env: "SEPOLIA_RPC", network: "testnet" },
  { name: "Polygon Amoy", env: "AMOY_RPC", network: "testnet" },
];
const STELLAR_NETWORKS: { name: string; env: string; network: Network }[] = [
  { name: "Stellar mainnet", env: "STELLAR_MAINNET_RPC", network: "mainnet" },
  { name: "Stellar testnet", env: "STELLAR_TESTNET_RPC", network: "testnet" },
];

// Every recipient type, each with a fixed key and a fresh random one.
const RECIPIENTS: { type: string; recipients: string[] }[] = [
  { type: "account (G)", recipients: ["GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK", randomAccount()] }, // fixed: deployed testnet clone
  { type: "muxed account (M)", recipients: ["MBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDUAAAAAAAAAAE2KX5I", randomMuxedAccount()] }, // fixed: account above, id 1234
  { type: "contract (C)", recipients: ["CADQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQP5KR", randomContract()] }, // fixed: contract ID 0x0707…07
];
// The smallest, a small and the largest index, at both speeds.
const INDICES = [0n, 7n, (1n << 256n) - 1n];
const SPEEDS: TransferSpeed[] = ["standard", "fast"];

const abi = parseAbi([
  "function implementation() view returns (address)",
  "function config() view returns (address)",
  "function computeAddress(bytes recipient, uint256 index, bool fast) view returns (address)",
]);

for (const chain of EVM_CHAINS) {
  const url = process.env[chain.env];
  const contracts = CONTRACTS[chain.network];
  describe.skipIf(!url)(`live: ${chain.name}`, () => {
    const client = createPublicClient({ transport: http(url ?? "http://unused.invalid") }); // built even when skipped

    it("factory and implementation point at the pinned contracts", async () => {
      const implementation = await client.readContract({ address: contracts.factory, abi, functionName: "implementation" });
      expect(implementation).toBe(contracts.forwarderImplementation);
      const config = await client.readContract({ address: contracts.forwarderImplementation, abi, functionName: "config" });
      expect(config).toBe(contracts.config);
    });

    // The XLM cases need no Stellar RPC: the vault is derived offline, and the EVM side commits it like any C recipient.
    const assets: DeliveryAsset[] = contracts.vaultFactory === null ? ["USDC"] : ["USDC", "XLM"];
    it.each(RECIPIENTS)("matches factory.computeAddress for $type recipients", async ({ recipients }) => {
      const network = chain.network;
      const cases = recipients.flatMap((recipient) =>
        assets.flatMap((deliveryAsset) =>
          INDICES.flatMap((index) => SPEEDS.map((speed) => ({ recipient, deliveryAsset, speed, index, network }))),
        ),
      );
      const onchain = await Promise.all(
        cases.map((testCase) => {
          const committed = testCase.deliveryAsset === "XLM" ? computeVaultAddress(testCase) : testCase.recipient;
          return client.readContract({
            address: contracts.factory,
            abi,
            functionName: "computeAddress",
            args: [stringToHex(committed), testCase.index, testCase.speed === "fast"],
          });
        }),
      );
      cases.forEach((testCase, i) => {
        expect(computeDepositAddress(testCase), JSON.stringify({ ...testCase, index: String(testCase.index) })).toBe(onchain[i] as Address);
      });
    }, 60_000);
  });
}

for (const stellar of STELLAR_NETWORKS) {
  const url = process.env[stellar.env];
  const factory = CONTRACTS[stellar.network].vaultFactory;
  describe.skipIf(!url || factory === null)(`live: ${stellar.name}`, () => {
    /** `VaultFactory.vault_address(recipient)`, simulated: read-only, so any unfunded source account will do. */
    async function vaultAddress(server: rpc.Server, recipient: string): Promise<string> {
      const tx = new TransactionBuilder(new Account(Keypair.random().publicKey(), "0"), {
        fee: BASE_FEE,
        networkPassphrase: PASSPHRASES[stellar.network],
      })
        .addOperation(new Contract(factory!).call("vault_address", nativeToScVal(Buffer.from(recipient, "ascii"))))
        .setTimeout(30)
        .build();
      const simulation = await server.simulateTransaction(tx);
      if (!rpc.Api.isSimulationSuccess(simulation) || !simulation.result) throw new Error(`vault_address(${recipient}) failed`);
      return scValToNative(simulation.result.retval) as string;
    }

    it.each(RECIPIENTS)("matches VaultFactory.vault_address for $type recipients", async ({ recipients }) => {
      const server = new rpc.Server(url ?? "http://unused.invalid");
      const onchain = await Promise.all(recipients.map((recipient) => vaultAddress(server, recipient)));
      recipients.forEach((recipient, i) => expect(computeVaultAddress({ recipient, network: stellar.network }), recipient).toBe(onchain[i]));
    }, 60_000);
  });
}
