#![cfg(test)]
extern crate std;

use super::*;
use crossmesh_interfaces::AquariusHop;
use crossmesh_interfaces::{OracleAsset, PriceData, VaultConfig, DISCOUNT_CAP_PPM, MAX_PRICE_AGE_CAP};
use soroban_sdk::testutils::{Address as _, Events as _, Ledger as _, MockAuth, MockAuthInvoke, MuxedAddress as _};
use soroban_sdk::xdr::ToXdr;
use soroban_sdk::{
    contract, contractimpl, symbol_short, token, vec, Address, Bytes, BytesN, Env, Event, IntoVal, MuxedAddress, Vec,
};
use test_support::{account_exists, contract_exists, create_account, native_sac, BASE_RESERVE};

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
    pub fn lastprice(e: Env, asset: OracleAsset) -> Option<PriceData> {
        e.storage().instance().get(&asset)
    }
    pub fn decimals(_e: Env) -> u32 {
        14
    }
}

/// Pays exactly `min_out`.
#[contract]
pub struct MockFiller;

#[contractimpl]
impl MockFiller {
    pub fn fill(
        e: Env,
        recipient: Address,
        _token_in: Address,
        _amount_in: i128,
        token_out: Address,
        min_out: i128,
        _data: Bytes,
    ) -> i128 {
        token::TokenClient::new(&e, &token_out).transfer(
            &e.current_contract_address(),
            MuxedAddress::from(recipient),
            &min_out,
        );
        min_out
    }
}

/// The USDC admin that funds vaults in these tests (on the real network Circle's forwarder pays a vault with
/// a plain SAC transfer, in its own transaction, before the relayer's `swap`); also the contract frame used
/// to deploy the native XLM asset contract.
#[contract]
pub struct UsdcAdmin;

#[contractimpl]
impl UsdcAdmin {}

/// A `try_*` client result for a contract function that panicked with contract error `code`.
fn contract_err<T, C>(code: u32) -> Result<Result<T, C>, Result<soroban_sdk::Error, soroban_sdk::InvokeError>> {
    Err(Ok(soroban_sdk::Error::from_contract_error(code)))
}

// ---------------------------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------------------------

const NOW: u64 = 1_800_000_000;
const XLM_PRICE: i128 = 50_000_000_000_000;
const USDC_PRICE: i128 = 100_000_000_000_000;
const ONE: i128 = 1_0000000;
const HUNDRED_USDC: i128 = 100 * ONE;

struct Fx {
    env: Env,
    admin: Address,
    usdc: Address,
    /// The real native XLM asset contract (CAP-0073 account creation).
    xlm: Address,
    rich: Address,
    relayer: Address,
    config: VaultConfig,
    factory: Address,
}

fn build_config(env: &Env, usdc: &Address, xlm: &Address, oracle: &Address) -> VaultConfig {
    VaultConfig {
        usdc: usdc.clone(),
        xlm: xlm.clone(),
        vault_wasm_hash: env.upload(vault::Vault),
        oracle: oracle.clone(),
        xlm_asset: OracleAsset::Other(symbol_short!("XLM")),
        usdc_asset: OracleAsset::Other(symbol_short!("USDC")),
        discount_ppm: 10_000, // 1 %
        max_price_age: 360,
        min_delivery: 20_000_000, // 2 XLM
    }
}

fn fixture() -> Fx {
    let env = Env::default();
    env.mock_all_auths();
    env.ledger().with_mut(|li| {
        li.timestamp = NOW;
        li.base_reserve = BASE_RESERVE;
    });
    let admin = MuxedAddress::generate(&env).address();
    let usdc = env.register_stellar_asset_contract_v2(admin.clone()).address();
    let usdc_admin = env.register(UsdcAdmin, ());
    let xlm = native_sac(&env, &usdc_admin);
    let rich = MuxedAddress::generate(&env).address();
    create_account(&env, &rich, 1_000_000_000 * ONE as i64);
    token::StellarAssetClient::new(&env, &usdc).set_admin(&usdc_admin);
    let oracle = env.register(MockOracle, ());
    let oc = MockOracleClient::new(&env, &oracle);
    oc.set_price(&OracleAsset::Other(symbol_short!("XLM")), &XLM_PRICE, &NOW);
    oc.set_price(&OracleAsset::Other(symbol_short!("USDC")), &USDC_PRICE, &NOW);
    let config = build_config(&env, &usdc, &xlm, &oracle);
    let factory = env.register(VaultFactory, (admin.clone(), config.clone()));
    let relayer = MuxedAddress::generate(&env).address();
    VaultFactoryClient::new(&env, &factory).set_relayer(&relayer, &true);
    Fx {
        env,
        admin,
        usdc,
        xlm,
        rich,
        relayer,
        config,
        factory,
    }
}

impl Fx {
    fn client(&self) -> VaultFactoryClient<'_> {
        VaultFactoryClient::new(&self.env, &self.factory)
    }

    fn new_account(&self) -> Address {
        MuxedAddress::generate(&self.env).address()
    }

    fn strkey(&self, addr: &Address) -> Bytes {
        addr.to_string().to_bytes()
    }

    fn filler(&self) -> Address {
        let f = self.env.register(MockFiller, ());
        token::TokenClient::new(&self.env, &self.xlm).transfer(
            &self.rich,
            MuxedAddress::from(f.clone()),
            &(1_000_000 * ONE),
        );
        f
    }

    fn usdc_balance(&self, of: &Address) -> i128 {
        token::TokenClient::new(&self.env, &self.usdc).balance(of)
    }

    fn xlm_balance(&self, of: &Address) -> i128 {
        token::TokenClient::new(&self.env, &self.xlm).balance(of)
    }

    fn vault_client(&self, vault: &Address) -> vault::VaultClient<'_> {
        vault::VaultClient::new(&self.env, vault)
    }

    fn bytes(&self, s: &[u8]) -> Bytes {
        Bytes::from_slice(&self.env, s)
    }
}

// ---------------------------------------------------------------------------------------------
// Constructor and configuration
// ---------------------------------------------------------------------------------------------

#[test]
fn constructor_stores_admin_and_config() {
    let fx = fixture();
    assert_eq!(fx.client().admin(), fx.admin);
    assert_eq!(fx.client().config(), fx.config);
    assert!(fx.client().is_relayer(&fx.relayer));
    assert!(!fx.client().is_relayer(&fx.admin));
}

#[test]
#[should_panic(expected = "Error(Contract, #2)")] // InvalidConfig
fn constructor_rejects_a_discount_above_the_cap() {
    let fx = fixture();
    let mut config = fx.config.clone();
    config.discount_ppm = DISCOUNT_CAP_PPM + 1;
    fx.env.register(VaultFactory, (fx.admin.clone(), config));
}

#[test]
#[should_panic(expected = "Error(Contract, #2)")] // InvalidConfig
fn constructor_rejects_a_price_age_above_the_cap() {
    let fx = fixture();
    let mut config = fx.config.clone();
    config.max_price_age = MAX_PRICE_AGE_CAP + 1;
    fx.env.register(VaultFactory, (fx.admin.clone(), config));
}

#[test]
fn set_discount_is_admin_only_bounded_by_the_cap_and_used_by_the_next_swap() {
    let fx = fixture();
    let client = fx.client();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = client.deploy(&owner);
    token::StellarAssetClient::new(&fx.env, &fx.usdc).mint(&vault_id, &HUNDRED_USDC);
    let filler = fx.filler();

    // Above the code-fixed cap: refused.
    assert_eq!(
        client.try_set_discount(&(DISCOUNT_CAP_PPM + 1)),
        contract_err(FactoryError::AboveCap as u32)
    );
    // At the cap: fine. 2 %: the floor for 100 USDC at $0.50 drops from 198 to 196 XLM.
    client.set_discount(&DISCOUNT_CAP_PPM);
    client.set_discount(&20_000);
    let events = fx.env.events().all().filter_by_contract(&fx.factory);
    assert_eq!(
        events,
        std::vec![DiscountSet { discount_ppm: 20_000 }.to_xdr(&fx.env, &fx.factory)]
    );
    assert_eq!(client.config().discount_ppm, 20_000);
    let out = client.swap(&fx.relayer, &owner, &Some(50 * ONE), &filler, &0, &fx.bytes(b""));
    assert_eq!(out, 50 * 196 * ONE / 100);

    // Not the admin: refused, nothing changes.
    fx.env.mock_auths(&[]);
    assert!(client.try_set_discount(&30_000).is_err());
    assert_eq!(client.config().discount_ppm, 20_000);
}

#[test]
fn set_relayer_and_set_admin_are_admin_only() {
    let fx = fixture();
    let client = fx.client();
    let new_relayer = Address::generate(&fx.env);
    client.set_relayer(&new_relayer, &true);
    assert_eq!(fx.env.auths()[0].0, fx.admin);
    assert!(client.is_relayer(&new_relayer));
    client.set_relayer(&new_relayer, &false);
    assert!(!client.is_relayer(&new_relayer));

    let new_admin = MuxedAddress::generate(&fx.env).address();
    client.set_admin(&new_admin);
    let signers: std::vec::Vec<Address> = fx.env.auths().into_iter().map(|(who, _)| who).collect();
    assert!(signers.contains(&fx.admin) && signers.contains(&new_admin));
    assert_eq!(client.admin(), new_admin);

    fx.env.mock_auths(&[]);
    assert!(client.try_set_relayer(&new_relayer, &true).is_err());
    assert!(client.try_set_admin(&fx.admin).is_err());
}

// ---------------------------------------------------------------------------------------------
// Address derivation and deployment
// ---------------------------------------------------------------------------------------------

/// The test vector shared with the verify SDK (`verify-sdk/test/vault.test.ts`): same factory, same owner,
/// same network passphrase ⇒ same vault address as `computeVaultAddress` in JavaScript.
#[test]
fn vault_address_matches_the_javascript_test_vector() {
    let env = Env::default();
    env.mock_all_auths();
    let network_id: [u8; 32] = env
        .crypto()
        .sha256(&Bytes::from_slice(&env, b"Test SDF Network ; September 2015"))
        .into();
    env.ledger().with_mut(|li| li.network_id = network_id);
    let admin = Address::generate(&env);
    let usdc = env.register_stellar_asset_contract_v2(admin.clone()).address();
    let xlm = env.register_stellar_asset_contract_v2(admin.clone()).address(); // any token address will do here
    let oracle = Address::generate(&env);
    let config = build_config(&env, &usdc, &xlm, &oracle);
    let factory = Address::from_str(&env, "CDBJUCCWJKJEFTFHFO5CKDTNYOSBFHT62WWY3HRYZRK766OERGMIGZY3");
    env.register_at(&factory, VaultFactory, (admin, config));
    let client = VaultFactoryClient::new(&env, &factory);

    let owner = Bytes::from_slice(&env, b"GDU64RNQMOBNNXUED7NN4G2NY3F6RXRYOT4MJD2EBOM7FSUQIODFSV4T");
    let expected = Address::from_str(&env, "CCLJZGOHFH55O22RL2SLJPQC7JRLZV7DFYHKILFADQBWL2HBGT6G25J5");
    assert_eq!(client.vault_address(&owner), expected);
    // Deploying lands exactly there.
    assert_eq!(client.deploy(&owner), expected);
}

#[test]
fn deploy_is_deterministic_idempotent_and_initialises_the_vault() {
    let fx = fixture();
    let client = fx.client();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);

    let predicted = client.vault_address(&owner);
    // Nothing is deployed there yet.
    assert!(!contract_exists(&fx.env, &predicted));
    let deployed = client.deploy(&owner);
    let events = fx.env.events().all().filter_by_contract(&fx.factory);
    assert_eq!(deployed, predicted);
    let expected = Deployed {
        owner: owner_addr,
        owner_strkey: owner.clone(),
        vault: deployed.clone(),
    };
    assert_eq!(events, std::vec![expected.to_xdr(&fx.env, &fx.factory)]);

    // The vault is stateless: the instance exists, and nothing else.
    assert!(contract_exists(&fx.env, &deployed));

    // Second deploy: same address, no second event.
    assert_eq!(client.deploy(&owner), deployed);
    assert_eq!(
        fx.env.events().all().filter_by_contract(&fx.factory),
        std::vec::Vec::<soroban_sdk::xdr::ContractEvent>::new()
    );

    // Different owners, different vaults; muxed and base owners differ too.
    let other = fx.new_account();
    assert_ne!(client.vault_address(&fx.strkey(&other)), deployed);
    let muxed = MuxedAddress::new(fx.new_account(), 1).to_strkey().to_bytes();
    assert_ne!(
        client.vault_address(&muxed),
        client.vault_address(&MuxedAddress::from_string_bytes(&muxed).address().to_string().to_bytes())
    );
}

#[test]
fn vault_address_and_deploy_accept_g_m_and_c_owners() {
    let fx = fixture();
    let client = fx.client();
    let g = fx.strkey(&fx.new_account());
    let m = MuxedAddress::new(fx.new_account(), 7).to_strkey().to_bytes();
    let c = fx.strkey(&fx.env.register(MockOracle, ())); // any contract address
    for owner in [g, m, c] {
        let predicted = client.vault_address(&owner);
        assert_eq!(client.deploy(&owner), predicted);
        assert!(contract_exists(&fx.env, &predicted));
    }
}

#[test]
fn deploy_rejects_a_malformed_owner() {
    let fx = fixture();
    let client = fx.client();
    assert!(client.try_vault_address(&fx.bytes(b"not a strkey")).is_err());
    // Valid shape, wrong checksum.
    assert!(client
        .try_deploy(&fx.bytes(b"GBCQATHVGEMQWIP3HANAMXICFDZRABAIJTGKLLJ2FX4L7VH6AXVDV5KX"))
        .is_err());
}

#[test]
fn swap_is_relayer_only_and_reaches_the_vault_through_the_factory() {
    let fx = fixture();
    let client = fx.client();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = client.deploy(&owner);
    token::StellarAssetClient::new(&fx.env, &fx.usdc).mint(&vault_id, &HUNDRED_USDC);
    let filler = fx.filler();

    let stranger = MuxedAddress::generate(&fx.env).address();
    assert_eq!(
        client.try_swap(&stranger, &owner, &None, &filler, &0, &fx.bytes(b"")),
        contract_err(FactoryError::NotRelayer as u32)
    );
    assert_eq!(fx.usdc_balance(&vault_id), HUNDRED_USDC);

    // Batch of 25, then the rest by default.
    let out = client.swap(&fx.relayer, &owner, &Some(25 * ONE), &filler, &0, &fx.bytes(b""));
    assert_eq!(fx.env.auths()[0].0, fx.relayer);
    assert_eq!(out, 25 * 198 * ONE / 100);
    assert!(account_exists(&fx.env, &owner_addr));
    assert_eq!(fx.usdc_balance(&vault_id), 75 * ONE);
    let out2 = client.swap(&fx.relayer, &owner, &None, &filler, &0, &fx.bytes(b""));
    assert_eq!(fx.usdc_balance(&vault_id), 0);
    assert_eq!(fx.xlm_balance(&owner_addr), out + out2);
}

#[test]
fn swap_requires_the_relayer_signature() {
    let fx = fixture();
    let client = fx.client();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = client.deploy(&owner);
    token::StellarAssetClient::new(&fx.env, &fx.usdc).mint(&vault_id, &HUNDRED_USDC);
    let filler = fx.filler();

    fx.env.mock_auths(&[]);
    assert!(client
        .try_swap(&fx.relayer, &owner, &None, &filler, &0, &fx.bytes(b""))
        .is_err());
    // The vault itself refuses anyone who is not its factory, relayer or not.
    assert!(fx
        .vault_client(&vault_id)
        .try_swap(
            &owner,
            &fx.factory,
            &fx.relayer,
            &filler,
            &HUNDRED_USDC,
            &0,
            &fx.bytes(b""),
            &fx.config
        )
        .is_err());
    assert_eq!(fx.usdc_balance(&vault_id), HUNDRED_USDC);
}

#[test]
#[should_panic]
fn constructor_rejects_usdc_equal_to_xlm() {
    let fx = fixture();
    let mut config = fx.config.clone();
    config.xlm = config.usdc.clone();
    fx.env.register(VaultFactory, (fx.admin.clone(), config));
}

// ---------------------------------------------------------------------------------------------
// End to end through the real Aquarius filler (with a router stand-in that has Aquarius's auth shape)
// ---------------------------------------------------------------------------------------------

/// Same shape as Aquarius's router: `user.require_auth()`, a direct pull of `token_in` from `user`,
/// output paid from its own inventory to `user`. Fixed rate 1 USDC → 2 XLM.
#[contract]
pub struct MockRouter;

#[contractimpl]
impl MockRouter {
    pub fn swap_chained(
        e: Env,
        user: Address,
        swaps_chain: Vec<AquariusHop>,
        token_in: Address,
        in_amount: u128,
        out_min: u128,
    ) -> u128 {
        user.require_auth();
        let last = swaps_chain.last().unwrap();
        let this = e.current_contract_address();
        token::TokenClient::new(&e, &token_in).transfer(&user, &this, &(in_amount as i128));
        let out = (in_amount as i128) * 2;
        assert!((out as u128) >= out_min, "OutMinNotSatisfied");
        token::TokenClient::new(&e, &last.2).transfer(&this, MuxedAddress::from(user), &out);
        out as u128
    }
}

#[test]
fn swap_through_the_aquarius_filler_under_real_authorization_rules() {
    let fx = fixture();
    let client = fx.client();
    let owner_addr = fx.new_account();
    let owner = fx.strkey(&owner_addr);
    let vault_id = client.deploy(&owner);
    token::StellarAssetClient::new(&fx.env, &fx.usdc).mint(&vault_id, &HUNDRED_USDC);

    let router = fx.env.register(MockRouter, ());
    token::TokenClient::new(&fx.env, &fx.xlm).transfer(
        &fx.rich,
        MuxedAddress::from(router.clone()),
        &(1_000_000 * ONE),
    );
    let filler = fx.env.register(
        aquarius_filler::AquariusFiller,
        (router.clone(), fx.config.vault_wasm_hash.clone()),
    );
    let (a, b) = if fx.usdc < fx.xlm {
        (fx.usdc.clone(), fx.xlm.clone())
    } else {
        (fx.xlm.clone(), fx.usdc.clone())
    };
    let hop: AquariusHop = (
        vec![&fx.env, a, b],
        BytesN::from_array(&fx.env, &[9u8; 32]),
        fx.xlm.clone(),
    );
    let data = vec![&fx.env, hop].to_xdr(&fx.env);

    // Only the relayer's signature is mocked; every contract-level authorization in the chain
    // factory → vault → filler → router → token is real. `MockAuth` can only stand in for a contract
    // address (it registers a mock `__check_auth` contract there), hence a contract-address relayer.
    let relayer = Address::generate(&fx.env);
    client.set_relayer(&relayer, &true);
    let amount: Option<i128> = None;
    fx.env.mock_auths(&[MockAuth {
        address: &relayer,
        invoke: &MockAuthInvoke {
            contract: &fx.factory,
            fn_name: "swap",
            args: (
                relayer.clone(),
                owner.clone(),
                amount,
                filler.clone(),
                0i128,
                data.clone(),
            )
                .into_val(&fx.env),
            sub_invokes: &[],
        },
    }]);
    let out = client.swap(&relayer, &owner, &None, &filler, &0, &data);

    // 100 USDC → 200 XLM at the mock rate; the floor (198) is met; everything reaches the owner.
    assert_eq!(out, 200 * ONE);
    assert!(account_exists(&fx.env, &owner_addr));
    assert_eq!(fx.xlm_balance(&owner_addr), 200 * ONE);
    assert_eq!(fx.usdc_balance(&vault_id), 0);
    assert_eq!(fx.usdc_balance(&router), HUNDRED_USDC);
    assert_eq!(fx.usdc_balance(&filler), 0);
    assert_eq!(fx.xlm_balance(&filler), 0);
}
