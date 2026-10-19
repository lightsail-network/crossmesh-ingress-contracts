//! Test-only helpers shared by the contract crates.
//!
//! The Soroban test environment does not create classic ledger entries on demand: a Stellar Asset
//! Contract transfer to a G account needs an `AccountEntry` and (for issued assets) a `TrustLineEntry`,
//! exactly as on a real network. These helpers write such entries, and deploy the NATIVE XLM asset
//! contract so that tests exercise the real CAP-0073 account-creation path.

use std::rc::Rc;

use soroban_sdk::testutils::StellarAssetContract;
use soroban_sdk::xdr::{
    AccountEntry, AccountEntryExt, AccountId, Asset, LedgerEntry, LedgerEntryData, LedgerEntryExt, LedgerKey,
    LedgerKeyAccount, LedgerKeyTrustLine, Limits, SequenceNumber, Thresholds, TrustLineAsset, TrustLineEntry,
    TrustLineEntryExt, VecM, WriteXdr,
};
use soroban_sdk::{Address, Bytes, Env};

/// Base reserve used by the fixtures (0.5 XLM, as on mainnet): a new account needs 2 × this.
pub const BASE_RESERVE: u32 = 5_000_000;

/// The classic account id behind a G address. Panics for contract addresses.
pub fn account_id(address: &Address) -> AccountId {
    AccountId::try_from(address).expect("not an account address")
}

fn account_key(address: &Address) -> Rc<LedgerKey> {
    Rc::new(LedgerKey::Account(LedgerKeyAccount {
        account_id: account_id(address),
    }))
}

/// Whether the account entry for `address` exists in the test ledger.
pub fn account_exists(env: &Env, address: &Address) -> bool {
    env.host().get_ledger_entry(&account_key(address)).unwrap().is_some()
}

/// Create the account entry for `address` holding `xlm` stroops. No-op if it already exists.
pub fn create_account(env: &Env, address: &Address, xlm: i64) {
    let key = account_key(address);
    if env.host().get_ledger_entry(&key).unwrap().is_some() {
        return;
    }
    let entry = Rc::new(LedgerEntry {
        last_modified_ledger_seq: 0,
        data: LedgerEntryData::Account(AccountEntry {
            account_id: account_id(address),
            balance: xlm,
            flags: 0,
            home_domain: Default::default(),
            inflation_dest: None,
            num_sub_entries: 0,
            seq_num: SequenceNumber(0),
            thresholds: Thresholds([1; 4]),
            signers: VecM::default(),
            ext: AccountEntryExt::V0,
        }),
        ext: LedgerEntryExt::V0,
    });
    env.host().add_ledger_entry(&key, &entry, None).unwrap();
}

/// Create an authorized, unlimited trustline from `address` (an existing account) to `sac`'s asset.
pub fn create_trustline(env: &Env, address: &Address, sac: &StellarAssetContract) {
    let id = account_id(address);
    let asset = match sac.asset() {
        Asset::CreditAlphanum4(a) => TrustLineAsset::CreditAlphanum4(a),
        Asset::CreditAlphanum12(a) => TrustLineAsset::CreditAlphanum12(a),
        Asset::Native => panic!("the native asset has no trustlines"),
    };
    let key = Rc::new(LedgerKey::Trustline(LedgerKeyTrustLine {
        account_id: id.clone(),
        asset: asset.clone(),
    }));
    let entry = Rc::new(LedgerEntry {
        last_modified_ledger_seq: 0,
        data: LedgerEntryData::Trustline(TrustLineEntry {
            account_id: id,
            asset,
            balance: 0,
            limit: i64::MAX,
            flags: 1, // AUTHORIZED
            ext: TrustLineEntryExt::V0,
        }),
        ext: LedgerEntryExt::V0,
    });
    env.host().add_ledger_entry(&key, &entry, None).unwrap();
}

/// Whether a contract instance exists at `address` in the test ledger (vaults have no view functions).
pub fn contract_exists(env: &Env, address: &Address) -> bool {
    use soroban_sdk::xdr::{ContractDataDurability, LedgerKeyContractData, ScVal};
    let key = Rc::new(LedgerKey::ContractData(LedgerKeyContractData {
        contract: address.into(),
        key: ScVal::LedgerKeyContractInstance,
        durability: ContractDataDurability::Persistent,
    }));
    env.host().get_ledger_entry(&key).unwrap().is_some()
}

/// The native XLM Stellar Asset Contract, deployed on first use. Deployment is a host function that
/// needs a contract frame, so any registered contract address serves as `frame`.
pub fn native_sac(env: &Env, frame: &Address) -> Address {
    let serialized = Bytes::from_slice(env, &Asset::Native.to_xdr(Limits::none()).unwrap());
    env.as_contract(frame, || {
        let deployer = env.deployer().with_stellar_asset(serialized.clone());
        let address = deployer.deployed_address();
        if address.exists() {
            address
        } else {
            deployer.deploy()
        }
    })
}
