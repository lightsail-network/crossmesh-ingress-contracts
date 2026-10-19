//! `VaultFactory`: one per network. Holds the immutable [`VaultConfig`], deploys [`Vault`]s at
//! addresses derived from the owner's strkey, manages the relayer set and is the only caller of
//! `Vault::swap` (design doc `stellar/docs/DESIGN.md`, §5.1). It takes no part in the mint: Circle's
//! permissionless `CctpForwarder.mint_and_forward` puts the USDC into the vault in its own transaction.
//!
//! Derivation (design §4): `salt = sha256(owner strkey ASCII bytes)`; the vault address is the
//! protocol's `ContractIdPreimage::Address { address: this factory, salt }`, independent of the code
//! or constructor arguments, so it can be computed offline and only this factory can deploy there.
//!
//! Relayers act only through the factory ([`VaultFactory::swap`]): a vault accepts `swap` from its factory
//! alone, so the relayer set is checked in one place and the vault never has to call back into the
//! factory (which the host would reject as re-entry).
//!
//! The factory has no upgrade path. Its only mutable state is the admin, the relayer set and the current
//! `discount_ppm` (at most `DISCOUNT_CAP_PPM`, 10 %, fixed in code); a relayer can only trigger
//! `Vault::swap`, whose worst case is bounded by that discount against an oracle price at most
//! `max_price_age` old (itself at most `MAX_PRICE_AGE_CAP`), so neither role can reach the principal.
//!
//! Rent: neither the factory nor the vaults extend TTLs from inside a call (that would also extend the
//! shared code entries and put an unpredictable rent bill on a random transaction). The operator keeps
//! the factory instance and the three code entries alive with `ExtendFootprintTTL` operations; anything
//! that does get archived is restored automatically by the next transaction touching it (design §5.5).
#![no_std]

#[cfg(test)]
mod test;

use crossmesh_interfaces::{VaultClient, VaultConfig, DISCOUNT_CAP_PPM, MAX_PRICE_AGE_CAP};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token, Address, Bytes,
    BytesN, ContractExecutable, Env, MuxedAddress,
};

#[contracttype]
#[derive(Clone)]
enum DataKey {
    Admin,
    Config,
    /// The admin-set `discount_ppm` overriding the constructor value (absent until first set).
    Discount,
    /// Instance storage: `Relayer(addr) -> bool`.
    Relayer(Address),
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum FactoryError {
    /// `swap` caller is not an enabled relayer.
    NotRelayer = 1,
    /// Constructor received an unusable configuration.
    InvalidConfig = 2,
    /// `set_discount` above `DISCOUNT_CAP_PPM`.
    AboveCap = 3,
}

/// Emitted once per vault, by [`VaultFactory::deploy`].
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deployed {
    #[topic]
    pub owner: Address,
    pub owner_strkey: Bytes,
    pub vault: Address,
}

/// Emitted by [`VaultFactory::set_relayer`].
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayerSet {
    #[topic]
    pub relayer: Address,
    pub enabled: bool,
}

/// Emitted by [`VaultFactory::set_discount`].
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscountSet {
    pub discount_ppm: u32,
}

/// Emitted by [`VaultFactory::set_admin`].
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminSet {
    pub admin: Address,
}

#[contract]
pub struct VaultFactory;

#[contractimpl]
impl VaultFactory {
    /// * `admin` – may add/remove relayers, move `discount_ppm` within the cap, and hand over the admin
    ///   role; nothing else.
    /// * `config` – immutable from here on except `discount_ppm` (see [`VaultFactory::set_discount`]).
    ///   `vault_wasm_hash` must already be uploaded; `discount_ppm` and `max_price_age` must be within the
    ///   code-fixed caps (`InvalidConfig`).
    pub fn __constructor(e: Env, admin: Address, config: VaultConfig) {
        if config.discount_ppm > DISCOUNT_CAP_PPM
            || config.max_price_age == 0
            || config.max_price_age > MAX_PRICE_AGE_CAP
            || config.min_delivery <= 0
            || config.usdc == config.xlm
            || config.oracle == config.usdc
            || config.oracle == config.xlm
        {
            panic_with_error!(&e, FactoryError::InvalidConfig);
        }
        let s = e.storage().instance();
        s.set(&DataKey::Admin, &admin);
        s.set(&DataKey::Config, &config);
    }

    /// The vault address for `owner` (G, M or C strkey as ASCII bytes), deployed or not.
    /// Rejects malformed strkeys (host error); any well-formed owner is accepted.
    pub fn vault_address(e: Env, owner: Bytes) -> Address {
        let _ = parse_owner(&owner);
        derive_address(&e, &owner)
    }

    /// Deploy the vault for `owner` if it does not exist yet; returns its address either way.
    /// Permissionless and harmless: the code is the factory's fixed wasm and the owner is fixed by
    /// the salt, so anyone (the relayer, the user, a third party) may deploy it — which is all an owner
    /// needs in order to `withdraw`.
    /// The factory keeps no registry (rent): `vault_address(owner)` is the lookup, and the
    /// `Deployed` event is the index for off-chain tooling.
    pub fn deploy(e: Env, owner: Bytes) -> Address {
        let config = read_config(&e);
        let muxed = parse_owner(&owner);
        let address = derive_address(&e, &owner);
        if address.exists() {
            return address;
        }
        // Stateless vault: no constructor arguments. Its identity is the address itself.
        let deployed = e
            .deployer()
            .with_current_contract(salt(&e, &owner))
            .deploy_contract(ContractExecutable::Wasm(config.vault_wasm_hash.clone()), ());
        debug_assert!(deployed == address);
        Deployed {
            owner: muxed.address(),
            owner_strkey: owner,
            vault: deployed.clone(),
        }
        .publish(&e);
        deployed
    }

    /// Settle `amount` of `owner`'s vault (default: its whole USDC balance) into XLM through `filler`,
    /// deploying the vault first if needed. Relayer-only; `min_out` is the relayer's own floor and
    /// `data` the filler's routing hint (design §5.3). Returns the XLM delivered.
    ///
    /// The USDC arrived earlier, in its own transaction, through Circle's permissionless
    /// `CctpForwarder.mint_and_forward`, which pays the vault named in the message. Whatever USDC a
    /// vault holds belongs to its owner and `swap` can only move it to that owner; a failed `swap`
    /// leaves it in the vault for a retry.
    pub fn swap(
        e: Env,
        relayer: Address,
        owner: Bytes,
        amount: Option<i128>,
        filler: Address,
        min_out: i128,
        data: Bytes,
    ) -> i128 {
        relayer.require_auth();
        if !is_relayer(&e, &relayer) {
            panic_with_error!(&e, FactoryError::NotRelayer);
        }
        settle(&e, relayer, owner, amount, filler, min_out, data)
    }

    /// Whether `addr` is an enabled relayer.
    pub fn is_relayer(e: Env, addr: Address) -> bool {
        is_relayer(&e, &addr)
    }

    /// Enable or disable a relayer. Admin-only.
    pub fn set_relayer(e: Env, addr: Address, enabled: bool) {
        read_admin(&e).require_auth();
        let s = e.storage().instance();
        if enabled {
            s.set(&DataKey::Relayer(addr.clone()), &true);
        } else {
            s.remove(&DataKey::Relayer(addr.clone()));
        }
        RelayerSet { relayer: addr, enabled }.publish(&e);
    }

    /// Set the current maximum discount against the oracle price, in ppm. Admin-only; must not exceed
    /// `DISCOUNT_CAP_PPM` (10 %, fixed in code). Takes effect on the next `swap` (the factory passes the
    /// current value to the vault). Too tight only makes swaps fail and retry; too loose is bounded by
    /// the cap.
    pub fn set_discount(e: Env, discount_ppm: u32) {
        read_admin(&e).require_auth();
        if discount_ppm > DISCOUNT_CAP_PPM {
            panic_with_error!(&e, FactoryError::AboveCap);
        }
        e.storage().instance().set(&DataKey::Discount, &discount_ppm);
        DiscountSet { discount_ppm }.publish(&e);
    }

    /// Hand the admin role to `new_admin`. Both the current and the new admin must authorize.
    pub fn set_admin(e: Env, new_admin: Address) {
        read_admin(&e).require_auth();
        new_admin.require_auth();
        e.storage().instance().set(&DataKey::Admin, &new_admin);
        AdminSet { admin: new_admin }.publish(&e);
    }

    /// The current admin.
    pub fn admin(e: Env) -> Address {
        read_admin(&e)
    }

    /// The configuration in force: the constructor's values with the current `discount_ppm`.
    pub fn config(e: Env) -> VaultConfig {
        read_config(&e)
    }
}

/// Deploy if needed, then `Vault::swap`. The caller has verified the relayer.
fn settle(
    e: &Env,
    relayer: Address,
    owner: Bytes,
    amount: Option<i128>,
    filler: Address,
    min_out: i128,
    data: Bytes,
) -> i128 {
    let config = read_config(e);
    let vault = VaultFactory::deploy(e.clone(), owner.clone());
    let amount = match amount {
        Some(a) => a,
        None => token::TokenClient::new(e, &config.usdc).balance(&vault),
    };
    VaultClient::new(e, &vault).swap(
        &owner,
        &e.current_contract_address(),
        &relayer,
        &filler,
        &amount,
        &min_out,
        &data,
        &config,
    )
}

fn read_admin(e: &Env) -> Address {
    e.storage().instance().get(&DataKey::Admin).unwrap()
}

/// The stored configuration with the admin-set `discount_ppm` applied, if any.
fn read_config(e: &Env) -> VaultConfig {
    let mut config: VaultConfig = e.storage().instance().get(&DataKey::Config).unwrap();
    if let Some(discount_ppm) = e.storage().instance().get::<_, u32>(&DataKey::Discount) {
        config.discount_ppm = discount_ppm;
    }
    config
}

fn is_relayer(e: &Env, addr: &Address) -> bool {
    e.storage()
        .instance()
        .get(&DataKey::Relayer(addr.clone()))
        .unwrap_or(false)
}

/// `sha256` of the owner strkey's ASCII bytes (design §4.2).
fn salt(e: &Env, owner: &Bytes) -> BytesN<32> {
    e.crypto().sha256(owner).into()
}

/// The protocol-defined address for `(this factory, salt(owner))` (design §4.3).
fn derive_address(e: &Env, owner: &Bytes) -> Address {
    e.deployer().with_current_contract(salt(e, owner)).deployed_address()
}

/// Parse the owner: G, M and C strkeys are all accepted (`MuxedAddress` is the SDK type that covers all
/// three); a malformed strkey is a host error. Nothing else is checked (design §4.1).
fn parse_owner(owner: &Bytes) -> MuxedAddress {
    MuxedAddress::from_string_bytes(owner)
}
