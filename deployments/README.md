# Deployments and source verification

Deployed addresses, and the Solidity standard-JSON inputs for verifying the contracts on Etherscan /
Polygonscan / Basescan (Verify & Publish). Every deployment below is built from commit `156581d` with OpenZeppelin
Contracts v5.6.1 (the pinned submodule) and the settings in `foundry.toml`.

## Addresses

Each network's contracts are at the same address on every chain it is deployed on.

### Mainnet (delivers to Stellar mainnet)

Deployed on Ethereum (chain ID 1), Polygon PoS (chain ID 137) and Base (chain ID 8453).

| Contract | Address |
| --- | --- |
| `Config` | `0xcB9014b9AC3Fc9BC8516F3B75464703dba30234c` |
| `DepositForwarder` (implementation) | `0xa49eFd75214749ce8d0f6d838a7a44A90E2A9A45` |
| `DepositFactory` | `0x8E6Ada2CFF0D86F5baFa575D11529FbFb50702e4` |

### Testnet (delivers to Stellar testnet)

Deployed on Ethereum Sepolia (chain ID 11155111) and Polygon Amoy (chain ID 80002).

| Contract | Address |
| --- | --- |
| `Config` | `0xac4a1A66F69820289A879F5D5D57828BF92cDa26` |
| `DepositForwarder` (implementation) | `0xb0216D95AFf228EB8b3A53C58f780D115eFfEC0F` |
| `DepositFactory` | `0xAD93f57DeA4F6bE812c0e1790dF5D3d1161BEd09` |

## Verification form fields

The same for every contract on every network:

| Field | Value |
| --- | --- |
| Compiler Type | Solidity (Standard-Json-Input) |
| Compiler Version | `v0.8.35+commit.47b9dedd` |
| Open Source License Type | MIT License (MIT) |

Mainnet and testnet use the same input files; only the constructor arguments differ (ABI-encoded,
without `0x`):

| Contract | File | Constructor |
| --- | --- | --- |
| `src/Config.sol:Config` | `Config.standard-input.json` | `constructor(address owner_)` — the owner |
| `src/DepositForwarder.sol:DepositForwarder` | `DepositForwarder.standard-input.json` | `constructor(IDepositConfig config_)` — the Config |
| `src/DepositFactory.sol:DepositFactory` | `DepositFactory.standard-input.json` | `constructor(address implementation_)` — the DepositForwarder implementation |

| Contract | Mainnet constructor arguments | Testnet constructor arguments |
| --- | --- | --- |
| `Config` | `000000000000000000000000072b521fa372771e69af11a0f74804b85146e41f` | `0000000000000000000000007b08fea04d4a89bcac93d7bfe667eabb35dd400e` |
| `DepositForwarder` | `000000000000000000000000cb9014b9ac3fc9bc8516f3b75464703dba30234c` | `000000000000000000000000ac4a1a66f69820289a879f5d5d57828bf92cda26` |
| `DepositFactory` | `000000000000000000000000a49efd75214749ce8d0f6d838a7a44a90e2a9a45` | `000000000000000000000000b0216d95aff228eb8b3a53c58f780d115effec0f` |

The contracts are created through CreateX, so the explorer may not detect the constructor arguments on
its own; paste them from the table.

## Reproducing the files

The JSON depends only on the sources and compiler settings. The address argument of
`forge verify-contract` is required but does not affect the output, and neither do the constructor
arguments. With forge 1.8.4 the files below come out byte-identical:

```sh
git checkout 156581d
git submodule update --init --recursive
mkdir -p deployments
for c in Config DepositForwarder DepositFactory; do
  forge verify-contract 0x0000000000000000000000000000000000000000 src/$c.sol:$c \
    --show-standard-json-input > deployments/$c.standard-input.json
done
```

Another forge version may format the JSON slightly differently, but it compiles to the same bytecode.
