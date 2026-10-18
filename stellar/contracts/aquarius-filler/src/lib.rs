//! `AquariusFiller`: a [`Filler`](crossmesh_interfaces::Filler) that converts the tokens a vault hands
//! it through the Aquarius AMM router (design doc `stellar/docs/DESIGN.md`, §5.3).
//!
//! The route is supplied per call in `data` as the XDR of `Vec<AquariusHop>`, exactly what Aquarius's
//! `find-path` API returns as `swap_chain_xdr`, so new pools or fee tiers never require a new adapter.
//! Every pool a route touches adds its own ledger entries and TTL extension to the transaction's rent, so
//! the relayer should prefer the shortest route that prices acceptably (`find-path` with `max_depth = 1`
//! first).
//! Only contracts running the vault code may call it. The adapter holds no funds between calls, is
//! immutable, and is retired simply by pointing the relayer at another filler. The vault verifies the
//! outcome by its own balance delta regardless.
//! Like the other contracts it never extends TTLs itself (design §5.5).
#![no_std]

#[cfg(test)]
mod test;

use crossmesh_interfaces::{AquariusHop, AquariusRouterClient};
use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::xdr::FromXdr;
use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, panic_with_error, token, vec, Address, Bytes,
    BytesN, Env, Executable, IntoVal, MuxedAddress, Symbol, Vec,
};

#[contracttype]
#[derive(Clone)]
enum DataKey {
    /// The Aquarius AMM router.
    Router,
    /// The wasm hash vaults run; only such contracts may call `fill`.
    VaultWasm,
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum FillerError {
    /// `amount_in` is not positive or `min_out` is negative.
    InvalidAmount = 1,
    /// `data` decodes to something other than an Aquarius swaps chain (bytes that are not XDR at all
    /// trap in the host's decoder instead).
    InvalidRoute = 2,
    /// The route has no hops.
    EmptyRoute = 3,
    /// The route's final token is not `token_out`.
    RouteTokenMismatch = 4,
    /// The router returned less than `min_out` (it should have failed itself).
    Shortfall = 5,
    /// `recipient` is not a contract running the vault code (or did not call directly).
    NotAVault = 6,
    /// The router paid the output without taking `amount_in` of `token_in` (a broken venue; refusing keeps
    /// stray input from piling up here).
    InputNotTaken = 7,
}

/// Emitted on every successful fill.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Filled {
    #[topic]
    pub recipient: Address,
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: i128,
    pub amount_out: i128,
}

#[contract]
pub struct AquariusFiller;

#[contractimpl]
impl AquariusFiller {
    /// * `router` – the Aquarius AMM router of this network.
    /// * `vault_wasm_hash` – the code a caller must run to be served (the factory's `vault_wasm_hash`);
    ///   a new vault wasm means a new adapter, which is how adapters are replaced anyway.
    pub fn __constructor(e: Env, router: Address, vault_wasm_hash: BytesN<32>) {
        e.storage().instance().set(&DataKey::Router, &router);
        e.storage().instance().set(&DataKey::VaultWasm, &vault_wasm_hash);
    }

    /// The Aquarius router this adapter swaps through.
    pub fn router(e: Env) -> Address {
        read_router(&e)
    }

    /// The vault code this adapter serves.
    pub fn vault_wasm(e: Env) -> BytesN<32> {
        e.storage().instance().get(&DataKey::VaultWasm).unwrap()
    }

    /// [`Filler::fill`](crossmesh_interfaces::Filler::fill): the caller has already transferred
    /// `amount_in` of `token_in` here; swap it through the router along the route in `data` and
    /// transfer everything received to `recipient`.
    ///
    /// Only a vault may call: `recipient.require_auth()` is satisfied automatically when the vault is
    /// the direct caller, and `recipient` must run the vault code (`NotAVault`).
    ///
    /// What that guards, and what it does not: a vault's funds are never at risk here — its `swap`
    /// transfers the USDC and calls `fill` in one atomic invocation that nobody can interleave. The check
    /// only concerns tokens that sit on this contract at rest, e.g. a mistaken transfer. This contract
    /// cannot tell who paid for `amount_in`; it only sees its own balance. Without the check, anyone could
    /// call `fill(recipient = themselves, amount_in = that balance)` without paying and walk away with the
    /// swapped output (`require_auth` does not help: they sign for their own address). With the check, such
    /// tokens are unspendable instead, since only vault code can call, and vault code always pays first.
    ///
    /// Authorization towards Aquarius: the router calls `user.require_auth()` (this contract is its
    /// direct invoker, so that is implicit) and then pulls the input with a direct
    /// `token_in.transfer(this, router, amount_in)`, one call deeper, which this contract pre-authorizes
    /// with `authorize_as_current_contract`. That entry authorizes exactly one transfer of exactly
    /// `amount_in`, so a router that takes a different amount fails at the host's auth check, and one that
    /// takes nothing is refused here (`InputNotTaken`). Any failure (bad route, pool killed, `out_min` not
    /// met) reverts the whole fill and therefore the caller's swap.
    pub fn fill(
        e: Env,
        recipient: Address,
        token_in: Address,
        amount_in: i128,
        token_out: Address,
        min_out: i128,
        data: Bytes,
    ) -> i128 {
        recipient.require_auth();
        // `executable()` is what the ledger has deployed at `recipient`: nothing, a Stellar Asset Contract,
        // or a wasm contract with a code hash. Only the vault code passes; see the doc comment above.
        let vault_wasm: BytesN<32> = e.storage().instance().get(&DataKey::VaultWasm).unwrap();
        match recipient.executable() {
            Some(Executable::Wasm(hash)) if hash == vault_wasm => {}
            _ => panic_with_error!(&e, FillerError::NotAVault),
        }
        if amount_in <= 0 || min_out < 0 {
            panic_with_error!(&e, FillerError::InvalidAmount);
        }
        let chain: Vec<AquariusHop> =
            Vec::from_xdr(&e, &data).unwrap_or_else(|_| panic_with_error!(&e, FillerError::InvalidRoute));
        let last = chain
            .last()
            .unwrap_or_else(|| panic_with_error!(&e, FillerError::EmptyRoute));
        if last.2 != token_out {
            panic_with_error!(&e, FillerError::RouteTokenMismatch);
        }

        let router = read_router(&e);
        let this = e.current_contract_address();
        let out = token::TokenClient::new(&e, &token_out);
        let input = token::TokenClient::new(&e, &token_in);
        let before = out.balance(&this);
        let input_before = input.balance(&this);

        e.authorize_as_current_contract(vec![
            &e,
            InvokerContractAuthEntry::Contract(SubContractInvocation {
                context: ContractContext {
                    contract: token_in.clone(),
                    fn_name: Symbol::new(&e, "transfer"),
                    args: (this.clone(), router.clone(), amount_in).into_val(&e),
                },
                sub_invocations: vec![&e],
            }),
        ]);
        AquariusRouterClient::new(&e, &router).swap_chained(
            &this,
            &chain,
            &token_in,
            &(amount_in as u128),
            &(min_out as u128),
        );

        // Trust balance deltas, not the router's return value: it must have taken exactly the input and
        // delivered at least the minimum.
        if input_before.checked_sub(input.balance(&this)) != Some(amount_in) {
            panic_with_error!(&e, FillerError::InputNotTaken);
        }
        let got = out.balance(&this).checked_sub(before).unwrap_or(0);
        if got < min_out {
            panic_with_error!(&e, FillerError::Shortfall);
        }
        out.transfer(&this, MuxedAddress::from(recipient.clone()), &got);
        Filled {
            recipient,
            token_in,
            token_out,
            amount_in,
            amount_out: got,
        }
        .publish(&e);
        got
    }
}

fn read_router(e: &Env) -> Address {
    e.storage().instance().get(&DataKey::Router).unwrap()
}
