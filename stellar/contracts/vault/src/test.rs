#![cfg(test)]
#![allow(clippy::too_many_arguments)] // the mock factory mirrors the real `swap` argument list
extern crate std;

use super::*;
use crossmesh_interfaces::{OracleAsset, PriceData, VaultConfig, DISCOUNT_CAP_PPM, MAX_PRICE_AGE_CAP};
use soroban_sdk::testutils::{Address as _, Events as _, Ledger as _, MuxedAddress as _, StellarAssetContract};
use soroban_sdk::xdr::{ScErrorCode, ScErrorType};
use soroban_sdk::{
    contract, contractimpl, contracttype, symbol_short, token, Address, Bytes, BytesN, ContractExecutable, Env, Event,
    MuxedAddress,
};
use test_support::{account_exists, contract_exists, create_account, create_trustline, native_sac, BASE_RESERVE};

// ---------------------------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------------------------

#[contract]
pub struct MockOracle;

#[contractimpl]
impl MockOracle {
    pub fn set_price(e: Env, asset: OracleAsset, price: i128, timestamp: u64) {
        e.storage().instance().set(&asset, &PriceData { price, timestamp });
    }
    pub fn clear(e: Env, asset: OracleAsset) {
        e.storage().instance().remove(&asset);
    }
    pub fn lastprice(e: Env, asset: OracleAsset) -> Option<PriceData> {
        e.storage().instance().get(&asset)
    }
    pub fn decimals(_e: Env) -> u32 {
        14
    }
}

/// Stands in for `VaultFactory`: deploys vaults at the derived address and forwards `swap` with its
/// own address as `factory`, exactly like the real one (which additionally gates relayers).
#[contract]
pub struct MockFactory;

#[contractimpl]
impl MockFactory {
    pub fn vault_address(e: Env, owner: Bytes) -> Address {
        let salt: BytesN<32> = e.crypto().sha256(&owner).into();
        e.deployer().with_current_contract(salt).deployed_address()
    }
    pub fn deploy(e: Env, owner: Bytes, wasm_hash: BytesN<32>) -> Address {
        let salt: BytesN<32> = e.crypto().sha256(&owner).into();
        e.deployer()
            .with_current_contract(salt)
            .deploy_contract(ContractExecutable::Wasm(wasm_hash), ())
    }
    pub fn swap(
        e: Env,
        vault: Address,
        owner: Bytes,
        relayer: Address,
        filler: Address,
        amount: i128,
        min_out: i128,
        data: Bytes,
        config: VaultConfig,
    ) -> i128 {
        crate::VaultClient::new(&e, &vault).swap(
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
}

#[contracttype]
#[derive(Clone)]
pub enum FillMode {
    /// Pays exactly `min_out`.
    PayWant,
    /// Pays nothing.
    PayNothing,
    /// Pays `min_out - 1`.
    PayShort,
    /// Pays `min_out + 5 XLM`.
    Overpay,
    /// Tries to re-enter the vault with a valid `withdraw` (owner and factory set via `set_target`).
    Reenter,
    /// Pays `min_out`, but first pulls whatever USDC the vault still holds, in the vault's name.
    Steal,
}

#[contract]
pub struct MockFiller;

#[contractimpl]
impl MockFiller {
    pub fn __constructor(e: Env, mode: FillMode) {
        e.storage().instance().set(&symbol_short!("mode"), &mode);
    }

    /// The `(owner, factory)` the `Reenter` mode uses for its nested `withdraw`.
    pub fn set_target(e: Env, owner: Bytes, factory: Address) {
        e.storage().instance().set(&symbol_short!("target"), &(owner, factory));
    }

    pub fn fill(
        e: Env,
        recipient: Address,
        token_in: Address,
        _amount_in: i128,
        token_out: Address,
        min_out: i128,
        _data: Bytes,
    ) -> i128 {
        let mode: FillMode = e.storage().instance().get(&symbol_short!("mode")).unwrap();
        let pay = match mode {
            FillMode::PayWant => min_out,
            FillMode::PayNothing => return 0,
            FillMode::PayShort => min_out - 1,
            FillMode::Overpay => min_out + 5 * ONE,
            FillMode::Reenter => {
                // A correctly formed call: only the host's re-entry rule can stop it.
                let (owner, factory): (Bytes, Address) = e.storage().instance().get(&symbol_short!("target")).unwrap();
                crate::VaultClient::new(&e, &recipient).withdraw(&owner, &factory, &token_out);
                return 0;
            }
            FillMode::Steal => {
                // The vault authorized nothing beyond its own direct transfer, so a nested transfer in
                // its name must fail the host's authorization check. Nothing is attempted when the vault
                // is already empty, so a whole-balance swap through this filler succeeds.
                let usdc = token::TokenClient::new(&e, &token_in);
                let remaining = usdc.balance(&recipient);
                if remaining > 0 {
                    usdc.transfer(&recipient, MuxedAddress::from(e.current_contract_address()), &remaining);
                }
                min_out
            }
        };
        token::TokenClient::new(&e, &token_out).transfer(
            &e.current_contract_address(),
            MuxedAddress::from(recipient),
            &pay,
        );
        pay
    }
}

/// A `try_*` client result for a contract function that panicked with contract error `code`.
fn contract_err<T, C>(code: u32) -> Result<Result<T, C>, Result<soroban_sdk::Error, soroban_sdk::InvokeError>> {
    Err(Ok(soroban_sdk::Error::from_contract_error(code)))
}

type TryResult = Result<Result<i128, soroban_sdk::Error>, Result<soroban_sdk::Error, soroban_sdk::InvokeError>>;

// ---------------------------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------------------------

const NOW: u64 = 1_800_000_000;
/// $0.50 with 14 decimals.
const XLM_PRICE: i128 = 50_000_000_000_000;
/// $1.00 with 14 decimals.
const USDC_PRICE: i128 = 100_000_000_000_000;
const ONE: i128 = 1_0000000;
const HUNDRED_USDC: i128 = 100 * ONE;
/// 100 USDC at $0.50/XLM minus 1 % = 198 XLM.
const FLOOR_FOR_HUNDRED: i128 = 198 * ONE;

struct Fx {
    env: Env,
    usdc_sac: StellarAssetContract,
    usdc: Address,
    /// The real native XLM asset contract: transfers to a missing G account create it (CAP-0073).
    xlm: Address,
    /// An account with plenty of XLM that funds fillers.
    rich: Address,
    oracle: Address,
    factory: Address,
    relayer: Address,
    vault_wasm: BytesN<32>,
    config: VaultConfig,
}

fn xlm_asset() -> OracleAsset {
    OracleAsset::Other(symbol_short!("XLM"))
}

fn usdc_asset() -> OracleAsset {
    OracleAsset::Other(symbol_short!("USDC"))
}

fn fixture() -> Fx {
    let env = Env::default();
    env.mock_all_auths();
    env.ledger().with_mut(|li| {
        li.timestamp = NOW;
        li.base_reserve = BASE_RESERVE;
    });
    let admin = Address::generate(&env);
    let usdc_sac = env.register_stellar_asset_contract_v2(admin);
    let usdc = usdc_sac.address();
    let oracle = env.register(MockOracle, ());
    let xlm = native_sac(&env, &oracle);
    let rich = MuxedAddress::generate(&env).address();
    create_account(&env, &rich, 1_000_000_000 * ONE as i64);
    let factory = env.register(MockFactory, ());
    let relayer = Address::generate(&env);
    let vault_wasm = env.upload(Vault);
    let oc = MockOracleClient::new(&env, &oracle);
    oc.set_price(&xlm_asset(), &XLM_PRICE, &NOW);
    oc.set_price(&usdc_asset(), &USDC_PRICE, &NOW);
    let config = VaultConfig {
        usdc: usdc.clone(),
        xlm: xlm.clone(),
        vault_wasm_hash: vault_wasm.clone(),
        oracle: oracle.clone(),
        xlm_asset: xlm_asset(),
        usdc_asset: usdc_asset(),
        discount_ppm: 10_000, // 1 %
        max_price_age: 360,
        min_delivery: 20_000_000, // 2 XLM
    };
    Fx {
        env,
        usdc_sac,
        usdc,
        xlm,
        rich,
        oracle,
        factory,
        relayer,
        vault_wasm,
        config,
    }
}

impl Fx {
    /// A fresh G address whose account does NOT exist yet.
    fn new_account(&self) -> Address {
        MuxedAddress::generate(&self.env).address()
    }

    /// A G address whose account exists and holds a USDC trustline (ready to `withdraw`).
    fn ready_account(&self) -> Address {
        let a = self.new_account();
        create_account(&self.env, &a, 10 * ONE as i64);
        create_trustline(&self.env, &a, &self.usdc_sac);
        a
    }

    fn strkey(&self, addr: &Address) -> Bytes {
        addr.to_string().to_bytes()
    }

    fn muxed_strkey(&self, base: &Address, id: u64) -> Bytes {
        MuxedAddress::new(base.clone(), id).to_strkey().to_bytes()
    }

    fn mock_factory(&self) -> MockFactoryClient<'_> {
        MockFactoryClient::new(&self.env, &self.factory)
    }

    /// Deploy the (stateless) vault for `owner` through the mock factory, as production does.
    fn vault(&self, owner: &Bytes) -> Address {
        self.mock_factory().deploy(owner, &self.vault_wasm)
    }

    fn vault_client(&self, vault: &Address) -> VaultClient<'_> {
        VaultClient::new(&self.env, vault)
    }

    fn filler(&self, mode: FillMode) -> Address {
        let f = self.env.register(MockFiller, (mode,));
        self.send_xlm(&f, 1_000_000 * ONE);
        f
    }

    fn send_xlm(&self, to: &Address, amount: i128) {
        token::TokenClient::new(&self.env, &self.xlm).transfer(&self.rich, MuxedAddress::from(to.clone()), &amount);
    }

    fn fund_usdc(&self, to: &Address, amount: i128) {
        token::StellarAssetClient::new(&self.env, &self.usdc).mint(to, &amount);
    }

    fn usdc_balance(&self, of: &Address) -> i128 {
        token::TokenClient::new(&self.env, &self.usdc).balance(of)
    }

    fn xlm_balance(&self, of: &Address) -> i128 {
        token::TokenClient::new(&self.env, &self.xlm).balance(of)
    }

    fn oracle(&self) -> MockOracleClient<'_> {
        MockOracleClient::new(&self.env, &self.oracle)
    }

    fn data(&self) -> Bytes {
        Bytes::from_slice(&self.env, b"route")
    }

    /// `Vault::swap` the way it is reached in production: invoked by the factory, which passes the
    /// owner, itself and its config.
    fn swap(&self, vault: &Address, owner: &Bytes, filler: &Address, amount: i128, min_out: i128) -> i128 {
        self.swap_cfg(vault, owner, filler, amount, min_out, &self.config)
    }

    fn swap_cfg(
        &self,
        vault: &Address,
        owner: &Bytes,
        filler: &Address,
        amount: i128,
        min_out: i128,
        config: &VaultConfig,
    ) -> i128 {
        self.mock_factory().swap(
            vault,
            owner,
            &self.relayer,
            filler,
            &amount,
            &min_out,
            &self.data(),
            config,
        )
    }

    fn try_swap(&self, vault: &Address, owner: &Bytes, filler: &Address, amount: i128, min_out: i128) -> TryResult {
        self.try_swap_cfg(vault, owner, filler, amount, min_out, &self.config)
    }

    fn try_swap_cfg(
        &self,
        vault: &Address,
        owner: &Bytes,
        filler: &Address,
        amount: i128,
        min_out: i128,
        config: &VaultConfig,
    ) -> TryResult {
        self.mock_factory().try_swap(
            vault,
            owner,
            &self.relayer,
            filler,
            &amount,
            &min_out,
            &self.data(),
            config,
        )
    }

    fn withdraw(&self, vault: &Address, owner: &Bytes, token: &Address) -> i128 {
        self.vault_client(vault).withdraw(owner, &self.factory, token)
    }

    fn try_withdraw(&self, vault: &Address, owner: &Bytes, token: &Address) -> TryResult {
        self.vault_client(vault).try_withdraw(owner, &self.factory, token)
    }

    /// Nothing moved: the vault still holds its USDC, the filler got none, the owner does not exist.
    fn assert_untouched(&self, vault_id: &Address, owner: &Address, filler: &Address) {
        assert_eq!(self.usdc_balance(vault_id), HUNDRED_USDC);
        assert_eq!(self.xlm_balance(vault_id), 0);
        assert_eq!(self.usdc_balance(filler), 0);
        assert!(!account_exists(&self.env, owner));
    }
}

// ---------------------------------------------------------------------------------------------
// Identity: the address is the state
// ---------------------------------------------------------------------------------------------

#[test]
fn deploy_puts_a_stateless_vault_at_the_derived_address() {
    let fx = fixture();
    let owner = fx.strkey(&fx.new_account());
    let predicted = fx.mock_factory().vault_address(&owner);
    assert!(!contract_exists(&fx.env, &predicted));

    let vault = fx.vault(&owner);

    assert_eq!(vault, predicted);
    assert!(contract_exists(&fx.env, &vault));
    // Nothing else exists for it: a second owner gets a different address.
    assert_ne!(fx.mock_factory().vault_address(&fx.strkey(&fx.new_account())), vault);
}

#[test]
fn calls_with_another_owner_or_another_factory_are_rejected_before_anything_else() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    // Right vault, somebody else's owner bytes.
    let other = fx.strkey(&fx.new_account());
    assert_eq!(
        fx.try_swap(&vault_id, &other, &filler, HUNDRED_USDC, 0),
        contract_err(VaultError::NotThisVault as u32)
    );
    assert_eq!(
        fx.try_withdraw(&vault_id, &other, &fx.usdc),
        contract_err(VaultError::NotThisVault as u32)
    );

    // Right owner, an impostor factory (its address does not derive to this vault).
    let impostor = fx.env.register(MockFactory, ());
    let r = MockFactoryClient::new(&fx.env, &impostor).try_swap(
        &vault_id,
        &owner,
        &fx.relayer,
        &filler,
        &HUNDRED_USDC,
        &0,
        &fx.data(),
        &fx.config,
    );
    assert_eq!(r, contract_err(VaultError::NotThisVault as u32));
    assert_eq!(
        fx.vault_client(&vault_id).try_withdraw(&owner, &impostor, &fx.usdc),
        contract_err(VaultError::NotThisVault as u32)
    );

    // Malformed owner bytes fail in the strkey parser.
    assert!(fx
        .try_swap(
            &vault_id,
            &Bytes::from_slice(&fx.env, b"GNOTASTRKEY"),
            &filler,
            HUNDRED_USDC,
            0
        )
        .is_err());
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_every_caller_but_the_factory() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    // Real authorization rules from here on (no mocking): a contract is authorized only for the
    // calls it makes directly, so only the factory can satisfy `factory.require_auth()`.
    fx.env.mock_auths(&[]);

    // Correct owner and factory arguments, but called from a transaction rather than by the factory.
    assert!(fx
        .vault_client(&vault_id)
        .try_swap(
            &owner,
            &fx.factory,
            &fx.relayer,
            &filler,
            &HUNDRED_USDC,
            &0,
            &fx.data(),
            &fx.config
        )
        .is_err());
    fx.assert_untouched(&vault_id, &owner_addr, &filler);

    // The genuine factory needs no mocked authorization at all.
    assert_eq!(fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), FLOOR_FOR_HUNDRED);
}

// ---------------------------------------------------------------------------------------------
// swap – happy paths
// ---------------------------------------------------------------------------------------------

#[test]
fn swap_creates_the_owner_account_and_pays_the_oracle_floor() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    assert!(!account_exists(&fx.env, &owner_addr));

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);
    let events = fx.env.events().all().filter_by_contract(&vault_id);

    assert_eq!(out, FLOOR_FOR_HUNDRED);
    // CAP-0073: the native transfer created the account with exactly the delivered XLM.
    assert!(account_exists(&fx.env, &owner_addr));
    assert_eq!(fx.xlm_balance(&owner_addr), FLOOR_FOR_HUNDRED);
    assert_eq!(fx.xlm_balance(&vault_id), 0);
    assert_eq!(fx.usdc_balance(&vault_id), 0);
    assert_eq!(fx.usdc_balance(&filler), HUNDRED_USDC);

    let expected = Swapped {
        owner: owner_addr.clone(),
        owner_strkey: owner.clone(),
        relayer: fx.relayer.clone(),
        filler: filler.clone(),
        amount_in: HUNDRED_USDC,
        amount_out: FLOOR_FOR_HUNDRED,
        paid_out: FLOOR_FOR_HUNDRED,
        floor: FLOOR_FOR_HUNDRED,
        want: FLOOR_FOR_HUNDRED,
        xlm_price: XLM_PRICE,
        usdc_price: USDC_PRICE,
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &vault_id)]);
}

#[test]
fn swap_pays_min_out_when_it_is_above_the_floor() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    let min_out = 199 * ONE;

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, min_out);

    assert_eq!(out, min_out);
    assert_eq!(fx.xlm_balance(&owner_addr), min_out);
}

#[test]
fn swap_of_a_partial_amount_leaves_the_rest_in_the_vault() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let out = fx.swap(&vault_id, &owner, &filler, 40 * ONE, 0);

    assert_eq!(out, 40 * 198 * ONE / 100);
    assert_eq!(fx.usdc_balance(&vault_id), 60 * ONE);
    assert_eq!(fx.xlm_balance(&owner_addr), out);

    // The second batch settles the remainder into the now-existing account.
    let out2 = fx.swap(&vault_id, &owner, &filler, 60 * ONE, 0);
    assert_eq!(fx.usdc_balance(&vault_id), 0);
    assert_eq!(fx.xlm_balance(&owner_addr), out + out2);
}

#[test]
fn swap_forwards_an_overpayment_and_any_prior_xlm_to_the_owner() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    // XLM that somehow sits in the vault beforehand belongs to the owner too.
    fx.send_xlm(&vault_id, 3 * ONE);
    let filler = fx.filler(FillMode::Overpay);

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);
    let events = fx.env.events().all().filter_by_contract(&vault_id);

    // The return value is this swap's delivery (floor + 5); the owner also gets the 3 that were there.
    assert_eq!(out, FLOOR_FOR_HUNDRED + 5 * ONE);
    assert_eq!(fx.xlm_balance(&owner_addr), out + 3 * ONE);
    assert_eq!(fx.xlm_balance(&vault_id), 0);
    // The event separates this swap's delivery from the total forwarded.
    let expected = Swapped {
        owner: owner_addr,
        owner_strkey: owner,
        relayer: fx.relayer.clone(),
        filler,
        amount_in: HUNDRED_USDC,
        amount_out: out,
        paid_out: out + 3 * ONE,
        floor: FLOOR_FOR_HUNDRED,
        want: FLOOR_FOR_HUNDRED,
        xlm_price: XLM_PRICE,
        usdc_price: USDC_PRICE,
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &vault_id)]);
}

#[test]
fn swap_delivers_to_the_base_account_of_a_muxed_owner() {
    let fx = fixture();
    let base = fx.new_account();
    let owner = fx.muxed_strkey(&base, 42);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);
    let events = fx.env.events().all().filter_by_contract(&vault_id);

    assert!(account_exists(&fx.env, &base));
    assert_eq!(fx.xlm_balance(&base), out);
    let expected = Swapped {
        owner: base.clone(),
        owner_strkey: owner.clone(),
        relayer: fx.relayer.clone(),
        filler,
        amount_in: HUNDRED_USDC,
        amount_out: out,
        paid_out: out,
        floor: FLOOR_FOR_HUNDRED,
        want: FLOOR_FOR_HUNDRED,
        xlm_price: XLM_PRICE,
        usdc_price: USDC_PRICE,
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &vault_id)]);
}

#[test]
fn swap_delivers_to_a_contract_owner() {
    let fx = fixture();
    let owner_contract = fx.env.register(MockOracle, ());
    let owner = fx.strkey(&owner_contract);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);

    assert_eq!(fx.xlm_balance(&owner_contract), out);
}

#[test]
fn swap_delivers_to_an_existing_account() {
    let fx = fixture();
    let owner_addr = fx.ready_account();
    let owner = fx.strkey(&owner_addr);
    let before = fx.xlm_balance(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let out = fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);

    assert_eq!(fx.xlm_balance(&owner_addr), before + out);
}

#[test]
fn swap_accepts_an_oracle_record_exactly_at_the_age_limit() {
    let fx = fixture();
    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &(NOW - 360));
    let owner = fx.strkey(&fx.new_account());
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    assert_eq!(fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), FLOOR_FOR_HUNDRED);
}

// ---------------------------------------------------------------------------------------------
// swap – rejections (nothing moves)
// ---------------------------------------------------------------------------------------------

#[test]
fn swap_rejects_a_config_whose_discount_exceeds_its_cap() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    let mut config = fx.config.clone();
    config.discount_ppm = DISCOUNT_CAP_PPM + 1;

    let r = fx.try_swap_cfg(&vault_id, &owner, &filler, HUNDRED_USDC, 0, &config);

    assert_eq!(r, contract_err(VaultError::InvalidConfig as u32));
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_a_zero_or_negative_amount() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    assert_eq!(
        fx.try_swap(&vault_id, &owner, &filler, 0, 0),
        contract_err(VaultError::InvalidAmount as u32)
    );
    assert_eq!(
        fx.try_swap(&vault_id, &owner, &filler, -1, 0),
        contract_err(VaultError::InvalidAmount as u32)
    );
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_an_amount_above_the_balance() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let r = fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC + 1, 0);

    assert_eq!(r, contract_err(VaultError::InsufficientBalance as u32));
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_a_missing_or_non_positive_oracle_price() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    let unavailable = contract_err(VaultError::OracleUnavailable as u32);

    fx.oracle().clear(&xlm_asset());
    assert_eq!(fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), unavailable);

    fx.oracle().set_price(&xlm_asset(), &0, &NOW);
    assert_eq!(fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), unavailable);

    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &NOW);
    fx.oracle().clear(&usdc_asset());
    assert_eq!(fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), unavailable);
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_a_stale_oracle_price() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    let stale = contract_err(VaultError::OracleStale as u32);

    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &(NOW - 361));
    assert_eq!(fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), stale);

    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &NOW);
    fx.oracle().set_price(&usdc_asset(), &USDC_PRICE, &(NOW - 361));
    assert_eq!(fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), stale);
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_an_oracle_price_from_the_future() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    // A record dated far ahead must not count as fresh forever.
    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &(NOW + 3600));
    assert_eq!(
        fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0),
        contract_err(VaultError::OracleStale as u32)
    );
    // A few seconds of skew between the feed's grid and ledger time is tolerated.
    fx.oracle().set_price(&xlm_asset(), &XLM_PRICE, &(NOW + 30));
    assert_eq!(fx.swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0), FLOOR_FOR_HUNDRED);
}

#[test]
fn swap_rejects_an_unusable_config() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);
    let invalid = contract_err(VaultError::InvalidConfig as u32);

    let mut c = fx.config.clone();
    c.min_delivery = 0;
    assert_eq!(
        fx.try_swap_cfg(&vault_id, &owner, &filler, HUNDRED_USDC, 0, &c),
        invalid
    );
    let mut c = fx.config.clone();
    c.max_price_age = 0;
    assert_eq!(
        fx.try_swap_cfg(&vault_id, &owner, &filler, HUNDRED_USDC, 0, &c),
        invalid
    );
    let mut c = fx.config.clone();
    c.xlm = fx.usdc.clone();
    assert_eq!(
        fx.try_swap_cfg(&vault_id, &owner, &filler, HUNDRED_USDC, 0, &c),
        invalid
    );
    let mut c = fx.config.clone();
    c.max_price_age = MAX_PRICE_AGE_CAP + 1;
    assert_eq!(
        fx.try_swap_cfg(&vault_id, &owner, &filler, HUNDRED_USDC, 0, &c),
        invalid
    );
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_rejects_a_delivery_below_the_minimum() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    // 0.1 USDC → 0.198 XLM, below the 2 XLM minimum.
    let r = fx.try_swap(&vault_id, &owner, &filler, ONE / 10, 0);

    assert_eq!(r, contract_err(VaultError::BelowMinDelivery as u32));
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_cannot_create_an_account_below_the_network_minimum() {
    // With `min_delivery` misconfigured far too low, the protocol itself refuses to create an
    // account for less than the minimum balance (2 × base reserve); the whole swap reverts.
    let fx = fixture();
    let mut config = fx.config.clone();
    config.min_delivery = 1;
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    let r = fx.try_swap_cfg(&vault_id, &owner, &filler, ONE / 10, 0, &config);

    assert!(r.is_err());
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_reverts_when_the_filler_pays_short_or_nothing() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);

    for mode in [FillMode::PayShort, FillMode::PayNothing] {
        let filler = fx.filler(mode);
        let r = fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);
        assert_eq!(r, contract_err(VaultError::FillShortfall as u32));
        // The USDC transfer to the filler was rolled back with the rest of the invocation.
        fx.assert_untouched(&vault_id, &owner_addr, &filler);
    }
}

#[test]
fn swap_reverts_when_the_filler_has_no_fill_function() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let not_a_filler = fx.env.register(MockFactory, ());

    let r = fx.try_swap(&vault_id, &owner, &not_a_filler, HUNDRED_USDC, 0);

    assert!(r.is_err());
    fx.assert_untouched(&vault_id, &owner_addr, &not_a_filler);
}

#[test]
fn swap_reverts_when_the_filler_re_enters_the_vault() {
    let fx = fixture();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::Reenter);
    MockFillerClient::new(&fx.env, &filler).set_target(&owner, &fx.factory);
    // Grant every authorization, including the owner's for the nested `withdraw`, so that the only thing
    // left to stop the re-entrant call is the host's re-entry rule.
    fx.env.mock_all_auths_allowing_non_root_auth();

    let r = fx.try_swap(&vault_id, &owner, &filler, HUNDRED_USDC, 0);

    assert_eq!(
        r,
        Err(Ok(soroban_sdk::Error::from_type_and_code(
            ScErrorType::Context,
            ScErrorCode::InvalidAction
        )))
    );
    fx.assert_untouched(&vault_id, &owner_addr, &filler);
}

#[test]
fn swap_reverts_when_the_filler_pulls_more_usdc_in_the_vaults_name() {
    let fx = fixture();
    let filler = fx.filler(FillMode::Steal);
    let a_addr = fx.new_account();
    let a = fx.strkey(&a_addr);
    let vault_a = fx.vault(&a);
    fx.fund_usdc(&vault_a, HUNDRED_USDC);
    let b_addr = fx.new_account();
    let b = fx.strkey(&b_addr);
    let vault_b = fx.vault(&b);
    fx.fund_usdc(&vault_b, HUNDRED_USDC);
    // Real authorization rules from here on: the factory → vault → filler chain needs no mocking, so
    // the only authorization in question is the one the filler tries to borrow.
    fx.env.mock_auths(&[]);

    // Control: with nothing left in the vault the same filler behaves, and the swap succeeds.
    assert_eq!(fx.swap(&vault_a, &a, &filler, HUNDRED_USDC, 0), FLOOR_FOR_HUNDRED);

    // The vault hands over 40 USDC; the filler tries to take the other 60 with the vault's authorization.
    let r = fx.try_swap(&vault_b, &b, &filler, 40 * ONE, 0);

    // A failed sub-invocation surfaces as the generic context error.
    assert_eq!(
        r,
        Err(Ok(soroban_sdk::Error::from_type_and_code(
            ScErrorType::Context,
            ScErrorCode::InvalidAction
        )))
    );
    assert_eq!(fx.usdc_balance(&vault_b), HUNDRED_USDC);
    assert_eq!(fx.xlm_balance(&vault_b), 0);
    assert!(!account_exists(&fx.env, &b_addr));
    // The filler holds exactly what the control swap paid it: the failed attempt moved nothing.
    assert_eq!(fx.usdc_balance(&filler), HUNDRED_USDC);
}

// ---------------------------------------------------------------------------------------------
// withdraw
// ---------------------------------------------------------------------------------------------

#[test]
fn withdraw_returns_all_usdc_to_the_owner() {
    let fx = fixture();
    let owner_addr = fx.ready_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);

    assert_eq!(fx.withdraw(&vault_id, &owner, &fx.usdc), HUNDRED_USDC);
    let events = fx.env.events().all().filter_by_contract(&vault_id);
    let auths = fx.env.auths();

    assert_eq!(fx.usdc_balance(&vault_id), 0);
    assert_eq!(fx.usdc_balance(&owner_addr), HUNDRED_USDC);
    let expected = Withdrawn {
        owner: owner_addr.clone(),
        owner_strkey: owner,
        token: fx.usdc.clone(),
        amount: HUNDRED_USDC,
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &vault_id)]);
    // The owner authorized it.
    assert_eq!(auths[0].0, owner_addr);
}

#[test]
fn withdraw_for_a_muxed_owner_is_signed_by_the_base_account() {
    let fx = fixture();
    let base = fx.ready_account();
    let owner = fx.muxed_strkey(&base, 7);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);

    assert_eq!(fx.withdraw(&vault_id, &owner, &fx.usdc), HUNDRED_USDC);
    let auths = fx.env.auths();

    assert_eq!(fx.usdc_balance(&base), HUNDRED_USDC);
    assert_eq!(auths[0].0, base);
}

#[test]
fn withdraw_to_a_contract_owner_needs_no_trustline() {
    let fx = fixture();
    let owner_contract = fx.env.register(MockOracle, ());
    let owner = fx.strkey(&owner_contract);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);

    assert_eq!(fx.withdraw(&vault_id, &owner, &fx.usdc), HUNDRED_USDC);
    assert_eq!(fx.usdc_balance(&owner_contract), HUNDRED_USDC);
}

#[test]
fn withdraw_works_for_any_token_the_vault_holds() {
    let fx = fixture();
    let owner_addr = fx.ready_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.send_xlm(&vault_id, 3 * ONE);
    let before = fx.xlm_balance(&owner_addr);

    assert_eq!(fx.withdraw(&vault_id, &owner, &fx.xlm), 3 * ONE);
    assert_eq!(fx.xlm_balance(&owner_addr), before + 3 * ONE);
}

#[test]
fn withdraw_fails_cleanly_without_a_trustline_or_account() {
    let fx = fixture();
    // Account exists, no USDC trustline.
    let no_trustline = fx.new_account();
    create_account(&fx.env, &no_trustline, 10 * ONE as i64);
    let owner = fx.strkey(&no_trustline);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    assert!(fx.try_withdraw(&vault_id, &owner, &fx.usdc).is_err());
    assert_eq!(fx.usdc_balance(&vault_id), HUNDRED_USDC);

    // Account does not exist at all: it cannot even authorize.
    let missing = fx.strkey(&fx.new_account());
    let vault_id = fx.vault(&missing);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    assert!(fx.try_withdraw(&vault_id, &missing, &fx.usdc).is_err());
    assert_eq!(fx.usdc_balance(&vault_id), HUNDRED_USDC);
}

#[test]
fn withdraw_rejects_an_empty_vault() {
    let fx = fixture();
    let owner = fx.strkey(&fx.ready_account());
    let vault_id = fx.vault(&owner);
    assert_eq!(
        fx.try_withdraw(&vault_id, &owner, &fx.usdc),
        contract_err(VaultError::NothingToWithdraw as u32)
    );
}

#[test]
fn withdraw_requires_the_owner_signature() {
    let fx = fixture();
    let owner = fx.strkey(&fx.ready_account());
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);

    fx.env.mock_auths(&[]);
    assert!(fx.try_withdraw(&vault_id, &owner, &fx.usdc).is_err());
    assert_eq!(fx.usdc_balance(&vault_id), HUNDRED_USDC);
}

#[test]
fn withdraw_does_not_need_the_relayer_and_swap_does_not_need_the_owner() {
    let fx = fixture();
    let owner_addr = fx.ready_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = fx.vault(&owner);
    fx.fund_usdc(&vault_id, HUNDRED_USDC);
    let filler = fx.filler(FillMode::PayWant);

    fx.swap(&vault_id, &owner, &filler, 50 * ONE, 0);
    let auths = fx.env.auths();
    assert!(auths.iter().all(|(who, _)| *who != owner_addr));

    fx.withdraw(&vault_id, &owner, &fx.usdc);
    let auths = fx.env.auths();
    assert!(!auths.is_empty() && auths.iter().all(|(who, _)| *who == owner_addr));
    assert_eq!(fx.usdc_balance(&owner_addr), 50 * ONE);
}
