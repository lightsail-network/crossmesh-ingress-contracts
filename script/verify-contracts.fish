#!/usr/bin/env fish
# Verify the three Cross Mesh Ingress contracts on an Etherscan-family explorer (Etherscan API V2: one key covers
# every chain; contract verification stays available on the free tier, including Base).
#
#   set -x ETHERSCAN_API_KEY <key>
#   fish script/verify-contracts.fish <ethereum|polygon|base|sepolia|amoy>
#
# The sources must be the deployed ones (main; contract sources = 156581d). Mainnet chains share one set of addresses
# and constructor arguments, testnet chains another — see deployments/README.md.
#
# forge 1.8 also submits each contract to Sourcify (no key needed) before the Etherscan step, so a run with a bad key
# still verifies on Sourcify and then stops at the Etherscan error.

fish_add_path -g ~/.foundry/bin

function fail
    echo "ERROR: $argv" >&2
    exit 1
end

switch "$argv[1]"
    case ethereum
        set chain mainnet
    case polygon
        set chain polygon
    case base
        set chain base
    case sepolia
        set chain sepolia
    case amoy
        set chain polygon-amoy
    case '*'
        fail "usage: fish script/verify-contracts.fish <ethereum|polygon|base|sepolia|amoy>"
end

switch $chain
    case mainnet polygon base
        set OWNER 0x072b521FA372771e69af11A0f74804b85146E41f
        set CONFIG 0xcB9014b9AC3Fc9BC8516F3B75464703dba30234c
        set IMPL 0xa49eFd75214749ce8d0f6d838a7a44A90E2A9A45
        set FACTORY 0x8E6Ada2CFF0D86F5baFa575D11529FbFb50702e4
    case '*'
        set OWNER 0x7b08fEA04d4a89bcAC93D7BfE667EAbB35dd400e
        set CONFIG 0xac4a1A66F69820289A879F5D5D57828BF92cDa26
        set IMPL 0xb0216D95AFf228EB8b3A53C58f780D115eFfEC0F
        set FACTORY 0xAD93f57DeA4F6bE812c0e1790dF5D3d1161BEd09
end

set -q REPO; or set REPO (path resolve (status dirname)/..)
cd $REPO; or fail "repo not found at $REPO"
set -q ETHERSCAN_API_KEY; or fail "set ETHERSCAN_API_KEY first (free key from etherscan.io → API Keys)"
git diff --quiet 156581d HEAD -- src foundry.toml; or fail "contract sources differ from 156581d"
git diff --quiet -- src foundry.toml; or fail "uncommitted changes in src/ or foundry.toml"

# constructor args: Config(owner), DepositForwarder(config), DepositFactory(implementation)
for spec in "$CONFIG src/Config.sol:Config $OWNER" \
        "$IMPL src/DepositForwarder.sol:DepositForwarder $CONFIG" \
        "$FACTORY src/DepositFactory.sol:DepositFactory $IMPL"
    set -l s (string split ' ' -- $spec)
    echo "== $chain: $s[2] at $s[1]"
    forge verify-contract $s[1] $s[2] --chain $chain --watch \
        --constructor-args (cast abi-encode "f(address)" $s[3])
    or fail "verification of $s[2] failed"
end
echo "== done"
