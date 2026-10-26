//! `Vault`: one instance per owner, deployed only by `VaultFactory` at an address derived from the
//! owner's strkey (design doc `stellar/docs/DESIGN.md`, §5.2).
//!
//! It receives USDC from Circle's `CctpForwarder` and has exactly two ways to move funds:
//!
//! - [`Vault::swap`] (callable only by the deploying `VaultFactory`, which admits relayers): hands
//!   `amount` USDC to a relayer-chosen filler, verifies by its OWN XLM balance delta that at least
//!   `max(min_out, oracle floor)` XLM came back, and transfers all its XLM to the owner (creating the
//!   owner's account if it does not exist, CAP-0073).
//! - [`Vault::withdraw`] (owner-only): returns every unit of a token it holds to the owner, unchanged.
//!
//! **The vault is stateless.** Soroban charges rent per byte kept in the ledger (for at least 120 days
//! on mainnet), and there is one vault per user, so the instance entry is the dominant per-user cost.
//! Storing nothing makes it ~100 bytes, the bare executable reference (design §5.5). Hence no constructor
//! and no instance storage. The vault's identity is its address, which the protocol derives from
//! `(factory, sha256(owner strkey))`: every call passes `owner` and `factory` as arguments and the vault
//! checks `deployer(factory, sha256(owner)).deployed_address() == current_contract_address()`. A match
//! proves both that `factory` deployed it and that `owner` is the committed owner (anything else would be
//! a hash collision). The configuration likewise arrives with each `swap` from the factory, which is
//! immutable and the only party allowed to call it.
//!
//! There is no upgrade path, no admin, and no other function that moves tokens. Rent: the contract never
//! extends TTLs itself; an archived instance is restored automatically by the next transaction that
//! touches it (design §5.5).
#![no_std]

#[cfg(test)]
mod test;

use crossmesh_interfaces::{
    FillerClient, OracleAsset, PriceData, ReflectorClient, VaultConfig, DISCOUNT_CAP_PPM, MAX_PRICE_AGE_CAP,
};
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, panic_with_error, token, Address, Bytes, BytesN, Env,
    MuxedAddress,
};

/// Parts per million: the fee/discount unit shared with the EVM `Config` (1e6 = 100 %).
pub const PPM: i128 = 1_000_000;
/// How far into the future an oracle timestamp may lie before it counts as stale (seconds).
pub const MAX_CLOCK_SKEW: u64 = 60;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum VaultError {
    /// `(factory, owner)` do not derive to this vault's address: wrong owner, or not the deploying factory.
    NotThisVault = 1,
    /// `amount` is zero or negative.
    InvalidAmount = 2,
    /// `amount` exceeds the vault's USDC balance.
    InsufficientBalance = 3,
    /// The oracle has no record (or a non-positive price) for a required asset.
    OracleUnavailable = 4,
    /// The oracle record is older than `max_price_age`.
    OracleStale = 5,
    /// `max(min_out, floor)` is below `min_delivery`.
    BelowMinDelivery = 6,
    /// The filler returned less XLM than required.
    FillShortfall = 7,
    /// `withdraw` of a token the vault holds none of.
    NothingToWithdraw = 8,
    /// Arithmetic overflow in the floor computation.
    Overflow = 9,
    /// Unusable configuration: discount above `DISCOUNT_CAP_PPM`, `max_price_age` zero or above
    /// `MAX_PRICE_AGE_CAP`, non-positive `min_delivery`, or USDC and XLM being the same contract (the factory
    /// enforces the same at construction).
    InvalidConfig = 10,
}

/// Emitted by [`Vault::swap`]. `owner` (topic) is the owner's base address; `owner_strkey` carries
/// the muxed form when the owner is an M address. `amount_out` is what the filler delivered in this
/// swap; `paid_out` is everything forwarded to the owner (it also includes any XLM the vault held before).
/// `xlm_price`, `usdc_price` and `discount_ppm` are the inputs of `floor`, so the event alone lets anyone
/// recompute it (`floor = amount_in × usdc_price × (PPM − discount_ppm) / (xlm_price × PPM)`).
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Swapped {
    #[topic]
    pub owner: Address,
    pub owner_strkey: Bytes,
    pub relayer: Address,
    pub filler: Address,
    pub amount_in: i128,
    pub amount_out: i128,
    pub paid_out: i128,
    pub floor: i128,
    pub want: i128,
    pub xlm_price: i128,
    pub usdc_price: i128,
    pub discount_ppm: u32,
}

/// Emitted by [`Vault::withdraw`].
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Withdrawn {
    #[topic]
    pub owner: Address,
    pub owner_strkey: Bytes,
    pub token: Address,
    pub amount: i128,
}

struct Floor {
    floor: i128,
    xlm_price: i128,
    usdc_price: i128,
}

#[contract]
pub struct Vault;

#[contractimpl]
impl Vault {
    /// Convert `amount` of this vault's USDC into XLM for the owner (design §5.2).
    ///
    /// * `owner`, `factory` – verified, not trusted: `(factory, sha256(owner))` must derive to this
    ///   vault's address (`NotThisVault`), and `factory` must be the direct invoker
    ///   (`factory.require_auth()`), which only the factory can satisfy.
    /// * `relayer` – verified by the factory; recorded in the event.
    /// * `config` – the factory's immutable configuration, passed along rather than stored (see above).
    ///
    /// `min_out` is the relayer's own floor (from a live quote); the effective requirement is
    /// `want = max(min_out, oracle floor)` and must be at least `config.min_delivery`. The USDC is
    /// transferred to `filler`, whose `fill` must return XLM to this vault within the same invocation;
    /// the vault trusts only its own balance delta. On success the ENTIRE XLM balance goes to the owner;
    /// the return value is this swap's delivery (`amount_out`), the total forwarded is `paid_out` in the
    /// event. Any failure reverts everything. The host forbids re-entry, so the filler cannot call back
    /// into this vault while it runs.
    #[allow(clippy::too_many_arguments)]
    pub fn swap(
        e: Env,
        owner: Bytes,
        factory: Address,
        relayer: Address,
        filler: Address,
        amount: i128,
        min_out: i128,
        data: Bytes,
        config: VaultConfig,
    ) -> i128 {
        let owner_muxed = require_this_vault(&e, &owner, &factory);
        factory.require_auth();
        if amount <= 0 {
            panic_with_error!(&e, VaultError::InvalidAmount);
        }
        let this = e.current_contract_address();
        let usdc = token::TokenClient::new(&e, &config.usdc);
        let xlm = token::TokenClient::new(&e, &config.xlm);
        if amount > usdc.balance(&this) {
            panic_with_error!(&e, VaultError::InsufficientBalance);
        }

        let Floor {
            floor,
            xlm_price,
            usdc_price,
        } = oracle_floor(&e, &config, amount);
        let want = if min_out > floor { min_out } else { floor };
        if want < config.min_delivery {
            panic_with_error!(&e, VaultError::BelowMinDelivery);
        }

        let before = xlm.balance(&this);
        // This vault is the direct invoker of the token contract, so its own authorization is implicit.
        usdc.transfer(&this, MuxedAddress::from(filler.clone()), &amount);
        let _reported = FillerClient::new(&e, &filler).fill(&this, &config.usdc, &amount, &config.xlm, &want, &data);
        let after = xlm.balance(&this);
        let delta = after
            .checked_sub(before)
            .unwrap_or_else(|| panic_with_error!(&e, VaultError::Overflow));
        if delta < want {
            panic_with_error!(&e, VaultError::FillShortfall);
        }

        // The whole balance: any XLM this vault ever holds belongs to its owner. For a non-existent
        // G owner the SAC creates the account (CAP-0073); `min_delivery` is set above that 1 XLM minimum so
        // the new account can also pay fees and add a trustline.
        xlm.transfer(&this, &owner_muxed, &after);

        Swapped {
            owner: owner_muxed.address(),
            owner_strkey: owner,
            relayer,
            filler,
            amount_in: amount,
            amount_out: delta,
            paid_out: after,
            floor,
            want,
            xlm_price,
            usdc_price,
            discount_ppm: config.discount_ppm,
        }
        .publish(&e);
        delta
    }

    /// Return every unit of `token` this vault holds to the owner, unchanged. Owner-only (for an M owner
    /// the underlying G signs; a C owner authorizes via `__check_auth` or by invoking directly).
    ///
    /// `owner` and `factory` are arguments, not storage, to keep the vault's ledger entry — and so the
    /// per-user rent — minimal (design §5.5); they must derive to this vault's address, which makes them
    /// as trustworthy as if they had been stored at deployment. `token` is normally USDC and lets the
    /// owner recover anything else that lands here. Fails at the token level if a G/M owner has no
    /// trustline for `token`.
    pub fn withdraw(e: Env, owner: Bytes, factory: Address, token: Address) -> i128 {
        let owner_muxed = require_this_vault(&e, &owner, &factory);
        owner_muxed.address().require_auth();
        let this = e.current_contract_address();
        let client = token::TokenClient::new(&e, &token);
        let amount = client.balance(&this);
        if amount <= 0 {
            panic_with_error!(&e, VaultError::NothingToWithdraw);
        }
        client.transfer(&this, &owner_muxed, &amount);
        Withdrawn {
            owner: owner_muxed.address(),
            owner_strkey: owner,
            token,
            amount,
        }
        .publish(&e);
        amount
    }
}

/// The vault's only identity check, replacing stored state: `(factory, sha256(owner))` must derive to
/// this very address. Returns the parsed owner, which may be a G, M or C strkey (`MuxedAddress` covers all
/// three; a malformed strkey is a host error).
fn require_this_vault(e: &Env, owner: &Bytes, factory: &Address) -> MuxedAddress {
    let salt: BytesN<32> = e.crypto().sha256(owner).into();
    let expected = e.deployer().with_address(factory.clone(), salt).deployed_address();
    if expected != e.current_contract_address() {
        panic_with_error!(e, VaultError::NotThisVault);
    }
    MuxedAddress::from_string_bytes(owner)
}

/// `floor = amount × P(USDC) × (1 − discount) / P(XLM)`: both prices come from the same feed, so their
/// decimals cancel, and both tokens have 7 decimals, so no scaling is needed. Reading USDC rather than
/// assuming it is worth exactly one base unit means a de-peg lowers the floor instead of freezing swaps.
fn oracle_floor(e: &Env, config: &VaultConfig, amount: i128) -> Floor {
    // The code-fixed bounds hold whatever configuration the factory passes.
    if config.discount_ppm > DISCOUNT_CAP_PPM
        || config.max_price_age == 0
        || config.max_price_age > MAX_PRICE_AGE_CAP
        || config.min_delivery <= 0
        || config.usdc == config.xlm
    {
        panic_with_error!(e, VaultError::InvalidConfig);
    }
    let oracle = ReflectorClient::new(e, &config.oracle);
    let now = e.ledger().timestamp();
    let xlm = fresh_price(e, &oracle, &config.xlm_asset, now, config.max_price_age);
    let usdc = fresh_price(e, &oracle, &config.usdc_asset, now, config.max_price_age);
    let keep = PPM - i128::from(config.discount_ppm);
    let overflow = || panic_with_error!(e, VaultError::Overflow);
    let numerator = amount
        .checked_mul(usdc.price)
        .and_then(|v| v.checked_mul(keep))
        .unwrap_or_else(overflow);
    let denominator = xlm.price.checked_mul(PPM).unwrap_or_else(overflow);
    Floor {
        floor: numerator / denominator,
        xlm_price: xlm.price,
        usdc_price: usdc.price,
    }
}

fn fresh_price(e: &Env, oracle: &ReflectorClient, asset: &OracleAsset, now: u64, max_age: u64) -> PriceData {
    let record = oracle
        .lastprice(asset)
        .unwrap_or_else(|| panic_with_error!(e, VaultError::OracleUnavailable));
    if record.price <= 0 {
        panic_with_error!(e, VaultError::OracleUnavailable);
    }
    // A record from the future is a broken feed, not a fresh price; a small skew between the feed's
    // sampling grid and the ledger close time is tolerated.
    if record.timestamp > now.saturating_add(MAX_CLOCK_SKEW) || now.saturating_sub(record.timestamp) > max_age {
        panic_with_error!(e, VaultError::OracleStale);
    }
    record
}
