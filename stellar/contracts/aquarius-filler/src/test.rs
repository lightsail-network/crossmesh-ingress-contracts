#![cfg(test)]
extern crate std;

use super::*;
use crossmesh_interfaces::AquariusHop;
use soroban_sdk::testutils::{Address as _, Events as _};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, token, vec, Address, Bytes, BytesN, ContractExecutable, Env,
    Event, MuxedAddress, Vec,
};

/// A stand-in for Aquarius's router with the same authorization shape: `user.require_auth()`, a
/// DIRECT pull of `token_in` from `user`, then the output paid from its own inventory to `user`.
/// It swaps at a fixed `rate_num / rate_den` and enforces Aquarius's sortedness and `out_min` rules.
/// `mode` lets tests make it misbehave.
#[contract]
pub struct MockRouter;

#[contracttype]
#[derive(Clone)]
pub enum RouterMode {
    Honest,
    /// Pays the output without taking the input.
    SkipsInput,
    /// Takes only half of the input.
    TakesHalf,
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum RouterError {
    PathIsEmpty = 307,
    TokensNotSorted = 2002,
    OutMinNotSatisfied = 2006,
}

#[contractimpl]
impl MockRouter {
    pub fn __constructor(e: Env, rate_num: i128, rate_den: i128, mode: RouterMode) {
        e.storage()
            .instance()
            .set(&soroban_sdk::symbol_short!("rate"), &(rate_num, rate_den));
        e.storage().instance().set(&soroban_sdk::symbol_short!("mode"), &mode);
    }

    pub fn swap_chained(
        e: Env,
        user: Address,
        swaps_chain: Vec<AquariusHop>,
        token_in: Address,
        in_amount: u128,
        out_min: u128,
    ) -> u128 {
        user.require_auth();
        let last = swaps_chain
            .last()
            .unwrap_or_else(|| panic_with_error!(&e, RouterError::PathIsEmpty));
        for hop in swaps_chain.iter() {
            let tokens = hop.0;
            if tokens.len() == 2 && tokens.get(0).unwrap() > tokens.get(1).unwrap() {
                panic_with_error!(&e, RouterError::TokensNotSorted);
            }
        }
        let this = e.current_contract_address();
        let mode: RouterMode = e.storage().instance().get(&soroban_sdk::symbol_short!("mode")).unwrap();
        let pull = match mode {
            RouterMode::Honest => in_amount as i128,
            RouterMode::SkipsInput => 0,
            RouterMode::TakesHalf => (in_amount / 2) as i128,
        };
        if pull > 0 {
            token::TokenClient::new(&e, &token_in).transfer(&user, &this, &pull);
        }
        let (num, den): (i128, i128) = e.storage().instance().get(&soroban_sdk::symbol_short!("rate")).unwrap();
        let out = (in_amount as i128) * num / den;
        if (out as u128) < out_min {
            panic_with_error!(&e, RouterError::OutMinNotSatisfied);
        }
        token::TokenClient::new(&e, &last.2).transfer(&this, MuxedAddress::from(user), &out);
        out as u128
    }
}

/// Stands in for a vault: pushes `token_in` to the filler and calls `fill`, exactly as the real vault
/// does. Its code hash is what the filler accepts as "vault code".
#[contract]
pub struct FakeVault;

#[contractimpl]
impl FakeVault {
    pub fn go(
        e: Env,
        filler: Address,
        token_in: Address,
        amount_in: i128,
        token_out: Address,
        min_out: i128,
        data: Bytes,
    ) -> i128 {
        let this = e.current_contract_address();
        token::TokenClient::new(&e, &token_in).transfer(&this, MuxedAddress::from(filler.clone()), &amount_in);
        crossmesh_interfaces::FillerClient::new(&e, &filler)
            .fill(&this, &token_in, &amount_in, &token_out, &min_out, &data)
    }
}

/// A `try_*` client result for a contract function that panicked with contract error `code`.
fn contract_err<T, C>(code: u32) -> Result<Result<T, C>, Result<soroban_sdk::Error, soroban_sdk::InvokeError>> {
    Err(Ok(soroban_sdk::Error::from_contract_error(code)))
}

const ONE: i128 = 1_0000000;
const HUNDRED: i128 = 100 * ONE;

struct Fx {
    env: Env,
    usdc: Address,
    xlm: Address,
    router: Address,
    filler: Address,
    vault_wasm: BytesN<32>,
}

/// Everything is set up under mocked auths, then mocking is switched OFF so `fill` runs under the
/// real authorization rules (contract invoker auth + `authorize_as_current_contract`).
fn fixture_with(mode: RouterMode) -> Fx {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let usdc = env.register_stellar_asset_contract_v2(admin.clone()).address();
    let xlm = env.register_stellar_asset_contract_v2(admin).address();
    // 1 USDC → 2 XLM.
    let router = env.register(MockRouter, (2i128, 1i128, mode));
    token::StellarAssetClient::new(&env, &xlm).mint(&router, &(1_000_000 * ONE));
    let vault_wasm = env.upload(FakeVault);
    let filler = env.register(AquariusFiller, (router.clone(), vault_wasm.clone()));
    env.mock_auths(&[]);
    Fx {
        env,
        usdc,
        xlm,
        router,
        filler,
        vault_wasm,
    }
}

fn fixture() -> Fx {
    fixture_with(RouterMode::Honest)
}

impl Fx {
    /// Deploy a "vault" (FakeVault code) at a deployer-derived address and give it USDC.
    fn vault(&self) -> Address {
        self.env.mock_all_auths();
        let deployer = Address::generate(&self.env);
        let salt = BytesN::<32>::from_array(&self.env, &[self.env.ledger().sequence() as u8; 32]);
        let v = self
            .env
            .deployer()
            .with_address(deployer, salt)
            .deploy_contract(ContractExecutable::Wasm(self.vault_wasm.clone()), ());
        token::StellarAssetClient::new(&self.env, &self.usdc).mint(&v, &HUNDRED);
        self.env.mock_auths(&[]);
        v
    }

    fn route(&self, token_out: &Address) -> Bytes {
        let (a, b) = if self.usdc < *token_out {
            (self.usdc.clone(), token_out.clone())
        } else {
            (token_out.clone(), self.usdc.clone())
        };
        let hop: AquariusHop = (
            vec![&self.env, a, b],
            BytesN::from_array(&self.env, &[1u8; 32]),
            token_out.clone(),
        );
        vec![&self.env, hop].to_xdr(&self.env)
    }

    fn balance(&self, token: &Address, of: &Address) -> i128 {
        token::TokenClient::new(&self.env, token).balance(of)
    }

    fn go(&self, vault: &Address, amount_in: i128, min_out: i128, data: &Bytes) -> i128 {
        FakeVaultClient::new(&self.env, vault).go(&self.filler, &self.usdc, &amount_in, &self.xlm, &min_out, data)
    }

    fn try_go(
        &self,
        vault: &Address,
        amount_in: i128,
        min_out: i128,
        data: &Bytes,
    ) -> Result<Result<i128, soroban_sdk::Error>, Result<soroban_sdk::Error, soroban_sdk::InvokeError>> {
        FakeVaultClient::new(&self.env, vault).try_go(&self.filler, &self.usdc, &amount_in, &self.xlm, &min_out, data)
    }
}

#[test]
fn constructor_stores_the_router_and_the_vault_code() {
    let fx = fixture();
    let c = AquariusFillerClient::new(&fx.env, &fx.filler);
    assert_eq!(c.router(), fx.router);
    assert_eq!(c.vault_wasm(), fx.vault_wasm);
}

#[test]
fn fill_swaps_through_the_router_and_pays_the_vault_under_real_auth_rules() {
    let fx = fixture();
    let vault = fx.vault();
    let data = fx.route(&fx.xlm);

    let got = fx.go(&vault, HUNDRED, 190 * ONE, &data);
    let events = fx.env.events().all().filter_by_contract(&fx.filler);

    assert_eq!(got, 200 * ONE);
    assert_eq!(fx.balance(&fx.xlm, &vault), 200 * ONE);
    assert_eq!(fx.balance(&fx.usdc, &fx.router), HUNDRED);
    // The adapter keeps nothing.
    assert_eq!(fx.balance(&fx.usdc, &fx.filler), 0);
    assert_eq!(fx.balance(&fx.xlm, &fx.filler), 0);
    let expected = Filled {
        recipient: vault.clone(),
        token_in: fx.usdc.clone(),
        token_out: fx.xlm.clone(),
        amount_in: HUNDRED,
        amount_out: 200 * ONE,
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &fx.filler)]);
}

#[test]
fn fill_reverts_when_the_router_cannot_meet_min_out() {
    let fx = fixture();
    let vault = fx.vault();
    let data = fx.route(&fx.xlm);

    let r = fx.try_go(&vault, HUNDRED, 201 * ONE, &data);

    assert_eq!(r, contract_err(RouterError::OutMinNotSatisfied as u32));
    // Everything rolled back: the vault still has its USDC, the router got none.
    assert_eq!(fx.balance(&fx.usdc, &vault), HUNDRED);
    assert_eq!(fx.balance(&fx.usdc, &fx.router), 0);
    assert_eq!(fx.balance(&fx.xlm, &vault), 0);
}

#[test]
fn fill_refuses_callers_that_are_not_vault_code() {
    let fx = fixture();
    let data = fx.route(&fx.xlm);
    let c = AquariusFillerClient::new(&fx.env, &fx.filler);
    // Tokens that happen to sit on the adapter must not be spendable by outsiders.
    fx.env.mock_all_auths();
    token::StellarAssetClient::new(&fx.env, &fx.usdc).mint(&fx.filler, &HUNDRED);
    fx.env.mock_auths(&[]);

    // A transaction calling `fill` directly (no vault): the recipient did not authorize → auth error.
    let stranger = Address::generate(&fx.env);
    assert!(c.try_fill(&stranger, &fx.usdc, &HUNDRED, &fx.xlm, &ONE, &data).is_err());

    // A contract with other code impersonating a vault (mock all auths so only the code check speaks).
    fx.env.mock_all_auths();
    let impostor = fx.env.register(MockRouter, (1i128, 1i128, RouterMode::Honest));
    assert_eq!(
        c.try_fill(&impostor, &fx.usdc, &HUNDRED, &fx.xlm, &ONE, &data),
        contract_err(FillerError::NotAVault as u32)
    );
    fx.env.mock_auths(&[]);

    assert_eq!(fx.balance(&fx.usdc, &fx.filler), HUNDRED);
    assert_eq!(fx.balance(&fx.xlm, &stranger), 0);
}

#[test]
fn fill_reverts_when_the_router_does_not_take_exactly_the_input() {
    // A router that pays without taking the input is refused by the adapter itself…
    let fx = fixture_with(RouterMode::SkipsInput);
    let vault = fx.vault();
    let data = fx.route(&fx.xlm);
    assert_eq!(
        fx.try_go(&vault, HUNDRED, 0, &data),
        contract_err(FillerError::InputNotTaken as u32)
    );
    assert_eq!(fx.balance(&fx.usdc, &vault), HUNDRED);
    assert_eq!(fx.balance(&fx.xlm, &vault), 0);

    // …and one that takes a different amount has no matching authorization: the adapter authorized
    // exactly one transfer of exactly `amount_in`, so the host rejects the router's pull.
    let fx = fixture_with(RouterMode::TakesHalf);
    let vault = fx.vault();
    let data = fx.route(&fx.xlm);
    assert!(fx.try_go(&vault, HUNDRED, 0, &data).is_err());
    assert_eq!(fx.balance(&fx.usdc, &vault), HUNDRED);
    assert_eq!(fx.balance(&fx.xlm, &vault), 0);
}

#[test]
fn fill_rejects_bad_amounts_and_routes() {
    let fx = fixture();
    let vault = fx.vault();
    let good = fx.route(&fx.xlm);

    assert_eq!(
        fx.try_go(&vault, 0, 0, &good),
        contract_err(FillerError::InvalidAmount as u32)
    );
    assert_eq!(
        fx.try_go(&vault, HUNDRED, -1, &good),
        contract_err(FillerError::InvalidAmount as u32)
    );

    // Bytes that are not XDR at all trap in the host's decoder (no contract-level error is possible).
    assert!(fx
        .try_go(&vault, HUNDRED, 0, &Bytes::from_slice(&fx.env, b"not xdr"))
        .is_err());
    // Valid XDR of the wrong type is caught by the adapter.
    assert_eq!(
        fx.try_go(&vault, HUNDRED, 0, &123i128.to_xdr(&fx.env)),
        contract_err(FillerError::InvalidRoute as u32)
    );

    let empty: Vec<AquariusHop> = vec![&fx.env];
    assert_eq!(
        fx.try_go(&vault, HUNDRED, 0, &empty.to_xdr(&fx.env)),
        contract_err(FillerError::EmptyRoute as u32)
    );

    // Route ends in USDC while XLM was requested.
    assert_eq!(
        fx.try_go(&vault, HUNDRED, 0, &fx.route(&fx.usdc)),
        contract_err(FillerError::RouteTokenMismatch as u32)
    );

    // Aquarius's own rule: pool tokens must be sorted.
    let (a, b) = if fx.usdc < fx.xlm {
        (fx.usdc.clone(), fx.xlm.clone())
    } else {
        (fx.xlm.clone(), fx.usdc.clone())
    };
    let unsorted: Vec<AquariusHop> = vec![
        &fx.env,
        (
            vec![&fx.env, b, a],
            BytesN::from_array(&fx.env, &[1u8; 32]),
            fx.xlm.clone(),
        ),
    ];
    assert_eq!(
        fx.try_go(&vault, HUNDRED, 0, &unsorted.to_xdr(&fx.env)),
        contract_err(RouterError::TokensNotSorted as u32)
    );

    assert_eq!(fx.balance(&fx.usdc, &vault), HUNDRED);
}
