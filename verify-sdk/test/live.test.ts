import { type Address, createPublicClient, http, parseAbi, stringToHex } from "viem";
import { describe, expect, it } from "vitest";
import { DEPLOYMENTS, type Network, computeDepositAddress } from "../src/index.js";
import { randomAccount, randomContract, randomMuxedAccount } from "./helpers.js";

// Against the DEPLOYED factory: computeDepositAddress must equal DepositFactory.computeAddress on chain.
// Each RPC env var is optional; its suite is skipped when unset.
const CHAINS: { name: string; env: string; network: Network }[] = [
  { name: "Ethereum", env: "ETHEREUM_RPC", network: "mainnet" },
  { name: "Polygon PoS", env: "POLYGON_RPC", network: "mainnet" },
  { name: "Ethereum Sepolia", env: "SEPOLIA_RPC", network: "testnet" },
  { name: "Polygon Amoy", env: "AMOY_RPC", network: "testnet" },
];

// Every recipient type, each with a fixed key and a fresh random one, at the smallest, a small and the
// largest index, in both modes.
const RECIPIENTS: { type: string; recipients: string[] }[] = [
  { type: "account (G)", recipients: ["GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KK", randomAccount()] }, // fixed: deployed testnet clone
  { type: "muxed account (M)", recipients: ["MBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDUAAAAAAAAAAE2KX5I", randomMuxedAccount()] }, // fixed: account above, id 1234
  { type: "contract (C)", recipients: ["CADQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQOBYHA4DQP5KR", randomContract()] }, // fixed: contract ID 0x0707…07
];
const INDICES = [0n, 7n, (1n << 256n) - 1n];

const abi = parseAbi([
  "function implementation() view returns (address)",
  "function computeAddress(bytes recipient, uint256 index, bool fast) view returns (address)",
]);

for (const chain of CHAINS) {
  const rpc = process.env[chain.env];
  describe.skipIf(!rpc)(`live: ${chain.name}`, () => {
    const client = createPublicClient({ transport: http(rpc ?? "http://unused.invalid") }); // built even when skipped
    const deployment = DEPLOYMENTS[chain.network]!;

    it("factory points at the hardcoded implementation", async () => {
      const impl = await client.readContract({ address: deployment.factory, abi, functionName: "implementation" });
      expect(impl).toBe(deployment.implementation);
    });

    it.each(RECIPIENTS)("matches factory.computeAddress for $type recipients", async ({ recipients }) => {
      const cases = recipients.flatMap((recipient) =>
        INDICES.flatMap((index) => [false, true].map((fast) => ({ recipient, index, fast }))),
      );
      const onchain = await Promise.all(
        cases.map((testCase) =>
          client.readContract({
            address: deployment.factory,
            abi,
            functionName: "computeAddress",
            args: [stringToHex(testCase.recipient), testCase.index, testCase.fast],
          }),
        ),
      );
      cases.forEach((testCase, i) => {
        expect(
          computeDepositAddress({ ...testCase, network: chain.network }),
          JSON.stringify({ ...testCase, index: String(testCase.index) }),
        ).toBe(
          onchain[i] as Address,
        );
      });
    }, 60_000);
  });
}
