# Source verification inputs

Solidity standard-JSON inputs for verifying the three contracts on Etherscan / Polygonscan (Verify &
Publish). They are generated from commit `156581d` with OpenZeppelin Contracts v5.6.1 (the pinned
submodule) and the settings in `foundry.toml`.

## Form fields

The same for all three contracts:

| Field | Value |
| --- | --- |
| Compiler Type | Solidity (Standard-Json-Input) |
| Compiler Version | `v0.8.35+commit.47b9dedd` |
| Open Source License Type | MIT License (MIT) |

Per contract (the constructor arguments are ABI-encoded, without `0x`):

| Contract | File | Constructor | Constructor Arguments |
| --- | --- | --- | --- |
| `src/Config.sol:Config` | `Config.standard-input.json` | `constructor(address owner_)` — the owner | `000000000000000000000000072b521fa372771e69af11a0f74804b85146e41f` |
| `src/DepositForwarder.sol:DepositForwarder` | `DepositForwarder.standard-input.json` | `constructor(IDepositConfig config_)` — the Config | `000000000000000000000000cb9014b9ac3fc9bc8516f3b75464703dba30234c` |
| `src/DepositFactory.sol:DepositFactory` | `DepositFactory.standard-input.json` | `constructor(address implementation_)` — the DepositForwarder implementation | `000000000000000000000000a49efd75214749ce8d0f6d838a7a44a90e2a9a45` |

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
