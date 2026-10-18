//! Shared types and cross-contract client interfaces for the XLM-delivery vaults
//! (`stellar/docs/DESIGN.md`). Every contract in the workspace depends on this crate and on
//! nothing else in the workspace, so the contracts never depend on each other's code.
#![no_std]

use soroban_sdk::{contractclient, contracttype, Address, Bytes, BytesN, Env, Symbol, Vec};

/// Per-network configuration. Set in `VaultFactory::__constructor` and handed to every `Vault::swap`
/// call by the factory. Everything is immutable except `discount_ppm`, which the factory admin may move
/// within the immutable `discount_cap_ppm` (design §5.1). Any other change means a new factory and
/// therefore new vault addresses.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VaultConfig {
    /// USDC Stellar Asset Contract.
    pub usdc: Address,
    /// Native XLM Stellar Asset Contract.
    pub xlm: Address,
    /// The only code a vault can ever run (`ContractExecutable::Wasm`).
    pub vault_wasm_hash: BytesN<32>,
    /// Reflector Pulse (SEP-40) price feed.
    pub oracle: Address,
    /// How XLM is identified in that feed.
    pub xlm_asset: OracleAsset,
    /// How USDC is identified in that feed. Both prices are read on every swap so a USDC de-peg
    /// lowers the floor instead of freezing swaps (the feed's base is USD).
    pub usdc_asset: OracleAsset,
    /// Immutable ceiling for `discount_ppm`, in millionths (1e6 = 100 %; 100_000 = 10 %), the same ppm
    /// unit as the EVM `Config` fee fields (`feePpm`, `maxFeePpm`). This is the worst case a user can
    /// verify. Must be < 1_000_000.
    pub discount_cap_ppm: u32,
    /// Current maximum discount of a fill against the oracle price, in millionths (10_000 = 1 %).
    /// Admin-tunable in the factory within `discount_cap_ppm`; the factory passes the current value.
    pub discount_ppm: u32,
    /// Maximum age of an oracle record, in seconds.
    pub max_price_age: u64,
    /// Minimum XLM (stroops) a single `swap` must deliver. Set above the account minimum (1 XLM today, may
    /// change) so the new account can also pay fees and add a trustline: 2 XLM.
    pub min_delivery: i128,
}

/// SEP-40 asset identifier as used by Reflector (`Stellar(Address)` for on-chain assets,
/// `Other(Symbol)` for external tickers such as `XLM`/`USDC` on the CEX feed).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OracleAsset {
    Stellar(Address),
    Other(Symbol),
}

/// SEP-40 price record. `price` carries the feed's `decimals()` fractional digits; `timestamp` is
/// unix seconds.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PriceData {
    pub price: i128,
    pub timestamp: u64,
}

/// The subset of the SEP-40 / Reflector Pulse interface the vault reads. Both quotes come from one
/// feed with one `decimals()`, so the vault never needs the scale: it only ever divides one price by
/// the other.
#[contractclient(name = "ReflectorClient")]
pub trait Reflector {
    fn lastprice(env: Env, asset: OracleAsset) -> Option<PriceData>;
}

/// A filler converts `token_in` into `token_out` for a vault (design §5.3).
///
/// Preconditions: the caller has already transferred `amount_in` of `token_in` to the filler.
/// Postcondition: before returning, the filler has transferred at least `min_out` of `token_out` to
/// `recipient`. The caller verifies this by its own balance delta and never trusts the return value.
/// `data` is opaque to the caller (venue routing chosen by the relayer).
#[contractclient(name = "FillerClient")]
pub trait Filler {
    fn fill(
        env: Env,
        recipient: Address,
        token_in: Address,
        amount_in: i128,
        token_out: Address,
        min_out: i128,
        data: Bytes,
    ) -> i128;
}

/// The factory's relayer registry (read by off-chain tooling and fillers outside a swap; nothing may
/// call the factory while one of its own calls is on the stack, which the host rejects as re-entry).
#[contractclient(name = "FactoryClient")]
pub trait Factory {
    fn is_relayer(env: Env, addr: Address) -> bool;
}

/// What the factory needs from a vault. Vaults are stateless to keep the per-user rent down (one vault
/// per user; every stored byte costs rent for at least 120 days): the factory passes the `owner`, its own
/// address and its immutable `config` with every call instead of the vault storing them; the vault
/// verifies that `(factory, sha256(owner))` derives to its own address and never has to store or read
/// anything (also avoiding a re-entrant read of the factory).
#[contractclient(name = "VaultClient")]
pub trait Vault {
    #[allow(clippy::too_many_arguments)]
    fn swap(
        env: Env,
        owner: Bytes,
        factory: Address,
        relayer: Address,
        filler: Address,
        amount: i128,
        min_out: i128,
        data: Bytes,
        config: VaultConfig,
    ) -> i128;
}

/// One hop of an Aquarius route: `(pool tokens sorted by address, pool hash, token to obtain)`. The
/// Aquarius backend's `find-path` API returns a whole chain as an XDR-encoded `Vec` of these.
pub type AquariusHop = (Vec<Address>, BytesN<32>, Address);

/// The Aquarius AMM router entrypoint used by the Aquarius filler. The router calls
/// `user.require_auth()`, pulls `in_amount` of `token_in` from `user` with a direct
/// `token_in.transfer(user, router, in_amount)`, swaps hop by hop, and transfers the output to `user`.
#[contractclient(name = "AquariusRouterClient")]
pub trait AquariusRouter {
    fn swap_chained(
        env: Env,
        user: Address,
        swaps_chain: Vec<AquariusHop>,
        token_in: Address,
        in_amount: u128,
        out_min: u128,
    ) -> u128;
}
