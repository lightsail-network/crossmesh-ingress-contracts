# /// script
# requires-python = ">=3.10"
# dependencies = ["click==8.5.0", "stellar-sdk==16.1.0", "strledger==0.11.0"]
# ///
"""Deploy the Stellar-side contracts (VaultFactory, AquariusFiller) of one network from a GitHub release built by
.github/workflows/stellar-release.yml. Vaults are not deployed here: the factory deploys each one lazily.

    uv run stellar/script/deploy.py --help
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import click
from stellar_sdk import (
    Account,
    Address,
    DecoratedSignature,
    Keypair,
    Network,
    SorobanServer,
    StrKey,
    TransactionBuilder,
    TransactionEnvelope,
    scval,
    xdr,
)
from stellar_sdk.exceptions import BaseRequestError, NotFoundError, PrepareTransactionException
from stellar_sdk.soroban_rpc import GetTransactionStatus, SendTransactionStatus

GH_REPO = "lightsail-network/crossmesh-ingress-contracts"
BUILD_WORKFLOW = "stellar-expert/soroban-build-workflow/.github/workflows/release.yml"  # signs the attestations
REPO = Path(__file__).resolve().parents[2]
CRATES = ("vault", "vault-factory", "aquarius-filler")

DISCOUNT_CAP_PPM = 100_000  # the contracts refuse anything above (DISCOUNT_CAP_PPM in crossmesh-interfaces)
DEFAULT_DISCOUNT_PPM = 10_000  # 1 %
MAX_PRICE_AGE = 360  # seconds: one 5-minute oracle update plus slack
MIN_DELIVERY = 20_000_000  # 2 XLM


@dataclass(frozen=True)
class NetworkConfig:
    passphrase: str
    rpc_url: str
    usdc: str
    xlm: str
    oracle: str  # Reflector Pulse, CEX feed
    router: str  # Aquarius


NETWORKS = {
    "testnet": NetworkConfig(
        passphrase=Network.TESTNET_NETWORK_PASSPHRASE,
        rpc_url="https://soroban-testnet.stellar.org",
        usdc="CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA",
        xlm="CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
        oracle="CCYOZJCOPG34LLQQ7N24YXBM7LL62R7ONMZ3G6WZAAYPB5OYKOMJRN63",
        router="CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD",
    ),
    "mainnet": NetworkConfig(
        passphrase=Network.PUBLIC_NETWORK_PASSPHRASE,
        rpc_url="https://mainnet.sorobanrpc.com",
        usdc="CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75",
        xlm="CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA",
        oracle="CAFJZQWSED6YAWZU3GWRTOCNPPCGBN32L7QV43XX5LZLFTK6JLN34DLN",
        router="CBQDHNBFBZYE4MKPWBSJOPIYLW4SFSXAXUTSXJN76GNKYVYPCKWC6QUK",
    ),
}


class Fail(click.ClickException):
    """Stops the run with `Error: <message>` and exit status 1."""


# ------------------------------------------------------ signers -------------------------------------------------------


class KeySigner:
    """A secret key or an account of a seed phrase, held in memory only."""

    def __init__(self, keypair: Keypair):
        self.keypair = keypair
        self.public_key = keypair.public_key

    def sign(self, te: TransactionEnvelope) -> TransactionEnvelope:
        te.sign(self.keypair)
        return te


class LedgerSigner:
    """An account of a Ledger's Stellar app, through strledger."""

    def __init__(self, index: int, hash_signing: bool):
        from strledger import StrLedger  # imported here: it opens the USB device

        try:
            self.client = StrLedger()
            self.keypair = self.client.get_keypair(keypair_index=index)
            app = self.client.get_app_info()
        except Exception as e:
            raise Fail(
                f"Ledger: {e or type(e).__name__} (is it connected, unlocked, with the Stellar app open?)"
            ) from e
        if hash_signing and not app.hash_signing_enabled:
            raise Fail("--hash-signing needs hash signing enabled in the Stellar app's settings")
        self.index = index
        self.hash_signing = hash_signing
        self.max_data_size = app.max_data_size
        self.public_key = self.keypair.public_key

    def sign(self, te: TransactionEnvelope) -> TransactionEnvelope:
        size = len(te.signature_base())  # what the device parses when it signs the full transaction
        if not self.hash_signing and self.max_data_size is not None and size > self.max_data_size:
            raise Fail(
                f"this {size}-byte transaction exceeds the Ledger's {self.max_data_size} bytes: use --hash-signing"
            )
        try:
            if self.hash_signing:
                click.echo(f"   confirm the hash {te.hash_hex()} on the Ledger")
                signature = self.client.sign_hash(te.hash(), keypair_index=self.index)
                te.signatures.append(DecoratedSignature(self.keypair.signature_hint(), signature))
                return te
            click.echo("   confirm the transaction on the Ledger")
            return self.client.sign_transaction(transaction_envelope=te, keypair_index=self.index)  # a signed copy
        except Fail:
            raise
        except Exception as e:
            raise Fail(f"Ledger: {e or type(e).__name__}") from e


def make_signer(signer: str, hd_path: int, hash_signing: bool) -> KeySigner | LedgerSigner:
    if signer == "key":
        secret = os.environ.get("STELLAR_SECRET_KEY") or click.prompt("secret key", hide_input=True)
        try:
            return KeySigner(Keypair.from_secret(secret.strip()))
        except Exception:
            raise Fail("not a valid secret key") from None
    if signer == "mnemonic":
        phrase = os.environ.get("STELLAR_MNEMONIC") or click.prompt("seed phrase", hide_input=True)
        try:
            return KeySigner(Keypair.from_mnemonic_phrase(" ".join(phrase.split()), index=hd_path))
        except Exception:
            raise Fail("not a valid seed phrase") from None
    return LedgerSigner(hd_path, hash_signing)


# ------------------------------------------------------ release -------------------------------------------------------


def gh(*args: str) -> str:
    try:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    except FileNotFoundError:
        raise Fail("the GitHub CLI (gh) is required") from None
    except subprocess.CalledProcessError as e:
        raise Fail(f"gh {args[0]} {args[1]}: {e.stderr.strip() or e.stdout.strip()}") from e


def fetch_release(tag: str) -> dict[str, bytes]:
    """The three wasm files of `tag`, cached in stellar/target/release-wasm/<tag>. Every file must carry a build
    attestation from StellarExpert's workflow, run on a GitHub-hosted runner for exactly this tag."""
    names = json.loads(
        gh("api", f"repos/{GH_REPO}/releases", "--paginate", "--jq", "[.[].tag_name]").replace("][", ",")
    )
    wasm_dir = REPO / "stellar" / "target" / "release-wasm" / tag
    wasm_dir.mkdir(parents=True, exist_ok=True)
    wasm = {}
    for crate in CRATES:
        releases = [n for n in names if n.startswith(f"{tag}_stellar_{crate}_pkg")]
        if len(releases) != 1:
            raise Fail(f"expected one release of {crate} for {tag}, found {len(releases)}")
        files = sorted(wasm_dir.glob(f"{crate}_v*.wasm"))
        if len(files) != 1:
            gh("release", "download", releases[0], "--repo", GH_REPO, "--pattern", "*.wasm", "-D", str(wasm_dir),
               "--clobber")  # fmt: skip
            files = sorted(wasm_dir.glob(f"{crate}_v*.wasm"))
        if len(files) != 1:
            raise Fail(f"release {releases[0]} has no single {crate} wasm")
        gh("attestation", "verify", str(files[0]), "--repo", GH_REPO, "--signer-workflow", BUILD_WORKFLOW,
           "--source-ref", f"refs/tags/{tag}", "--deny-self-hosted-runners")  # fmt: skip
        wasm[crate] = files[0].read_bytes()
    return wasm


# ------------------------------------------------------- chain --------------------------------------------------------


def salt(tag: str, crate: str) -> bytes:
    """The deploy salt: one address per deployer, release and contract, so re-runs find their own deployment."""
    return hashlib.sha256(f"crossmesh-ingress/{tag}/{crate}".encode()).digest()


class Chain:
    def __init__(self, net: NetworkConfig, rpc_url: str, source: str):
        self.net = net
        self.server = SorobanServer(rpc_url)
        self.source = source  # the deployer: source of every transaction; contract addresses derive from it
        try:
            passphrase = self.server.get_network().passphrase
        except Exception as e:
            raise Fail(f"RPC {rpc_url}: {e}") from e
        if passphrase != net.passphrase:
            raise Fail(f"RPC {rpc_url} serves '{passphrase}', not '{net.passphrase}'")

    def balance(self) -> str | None:
        """The source account's XLM balance, or None if the account does not exist."""
        key = xdr.LedgerKey(
            type=xdr.LedgerEntryType.ACCOUNT,
            account=xdr.LedgerKeyAccount(Keypair.from_public_key(self.source).xdr_account_id()),
        )
        entries = self.server.get_ledger_entries([key]).entries
        if not entries:
            return None
        return f"{xdr.LedgerEntryData.from_xdr(entries[0].xdr).account.balance.int64 / 10**7:.7f}"

    def contract_id(self, crate: str, tag: str) -> str:
        """The address `stellar contract deploy --salt` gives `crate` deployed by the source for `tag`."""
        preimage = xdr.HashIDPreimage(
            type=xdr.EnvelopeType.ENVELOPE_TYPE_CONTRACT_ID,
            contract_id=xdr.HashIDPreimageContractID(
                network_id=xdr.Hash(hashlib.sha256(self.net.passphrase.encode()).digest()),
                contract_id_preimage=xdr.ContractIDPreimage(
                    type=xdr.ContractIDPreimageType.CONTRACT_ID_PREIMAGE_FROM_ADDRESS,
                    from_address=xdr.ContractIDPreimageFromAddress(
                        address=Address(self.source).to_xdr_sc_address(), salt=xdr.Uint256(salt(tag, crate))
                    ),
                ),
            ),
        )
        return StrKey.encode_contract(hashlib.sha256(preimage.to_xdr_bytes()).digest())

    def code_exists(self, wasm_hash: bytes) -> bool:
        key = xdr.LedgerKey(
            type=xdr.LedgerEntryType.CONTRACT_CODE, contract_code=xdr.LedgerKeyContractCode(hash=xdr.Hash(wasm_hash))
        )
        return bool(self.server.get_ledger_entries([key]).entries)

    def contract_code(self, contract_id: str) -> bytes | None:
        """The wasm hash a deployed contract runs, or None if nothing is deployed there."""
        key = xdr.LedgerKey(
            type=xdr.LedgerEntryType.CONTRACT_DATA,
            contract_data=xdr.LedgerKeyContractData(
                contract=Address(contract_id).to_xdr_sc_address(),
                key=xdr.SCVal(type=xdr.SCValType.SCV_LEDGER_KEY_CONTRACT_INSTANCE),
                durability=xdr.ContractDataDurability.PERSISTENT,
            ),
        )
        entries = self.server.get_ledger_entries([key]).entries
        if not entries:
            return None
        executable = xdr.LedgerEntryData.from_xdr(entries[0].xdr).contract_data.val.instance.executable
        return executable.wasm_hash.hash if executable.wasm_hash else None

    def view(self, contract_id: str, function: str, *args: xdr.SCVal):
        """A read-only call, simulated and never sent; None if it fails (e.g. nothing deployed there)."""
        tx = (
            TransactionBuilder(Account(self.source, 0), self.net.passphrase)
            .append_invoke_contract_function_op(contract_id, function, list(args))
            .set_timeout(60)
            .build()
        )
        sim = self.server.simulate_transaction(tx)
        if sim.error or not sim.results:
            return None
        return scval.to_native(xdr.SCVal.from_xdr(sim.results[0].xdr))


@dataclass
class Sender:
    """Builds, simulates, signs, sends and waits for transactions from the signer's account."""

    chain: Chain
    signer: KeySigner | LedgerSigner
    inclusion_fee: int
    confirm: bool

    def submit(self, label: str, add_op: Callable[[TransactionBuilder], TransactionBuilder]) -> None:
        server, net = self.chain.server, self.chain.net
        builder = TransactionBuilder(server.load_account(self.signer.public_key), net.passphrase, self.inclusion_fee)
        try:
            te = server.prepare_transaction(add_op(builder).set_timeout(900).build())
        except PrepareTransactionException as e:
            raise Fail(f"{label}: simulation failed: {e.simulate_transaction_response.error}") from e
        click.echo(f"== {label}: fee up to {te.transaction.fee / 10**7:.7f} XLM")
        if self.confirm and not click.confirm("   send it?", default=False):
            raise Fail("aborted")
        te = self.signer.sign(te)
        for _ in range(5):
            sent = server.send_transaction(te)
            if sent.status != SendTransactionStatus.TRY_AGAIN_LATER:
                break
            time.sleep(5)
        if sent.status != SendTransactionStatus.PENDING:
            raise Fail(f"{label}: rejected ({sent.status.value}): {sent.error_result_xdr}")
        result = server.poll_transaction(sent.hash, max_attempts=120)
        if result.status != GetTransactionStatus.SUCCESS:
            raise Fail(f"{label}: tx {sent.hash} {result.status.value}; rerun the command once it settles")
        click.echo(f"   tx {sent.hash}")


# ------------------------------------------------------- steps --------------------------------------------------------


def factory_config(net: NetworkConfig, vault_hash: bytes, discount_ppm: int) -> xdr.SCVal:
    return scval.to_struct(
        {
            "usdc": scval.to_address(net.usdc),
            "xlm": scval.to_address(net.xlm),
            "vault_wasm_hash": scval.to_bytes(vault_hash),
            "oracle": scval.to_address(net.oracle),
            "xlm_asset": scval.to_enum("Other", scval.to_symbol("XLM")),
            "usdc_asset": scval.to_enum("Other", scval.to_symbol("USDC")),
            "discount_ppm": scval.to_uint32(discount_ppm),
            "max_price_age": scval.to_uint64(MAX_PRICE_AGE),
            "min_delivery": scval.to_int128(MIN_DELIVERY),
        }
    )


def do_upload(sender: Sender, wasm: dict[str, bytes]) -> None:
    chain = sender.chain
    for crate, code in wasm.items():
        h = hashlib.sha256(code).digest()
        if chain.code_exists(h):
            click.echo(f"== upload {crate}: already on chain ({h.hex()})")
            continue
        sender.submit(f"upload {crate}", lambda b, code=code: b.append_upload_contract_wasm_op(code))
        if not chain.code_exists(h):
            raise Fail(f"{crate} code {h.hex()} not found after the upload")


def do_deploy(sender: Sender, wasm: dict[str, bytes], tag: str, admin: str, relayers: list[str], discount_ppm: int):
    chain, net = sender.chain, sender.chain.net
    hashes = {crate: hashlib.sha256(code).digest() for crate, code in wasm.items()}
    missing = [crate for crate, h in hashes.items() if not chain.code_exists(h)]
    if missing:
        raise Fail(f"code not uploaded yet ({', '.join(missing)}): run the upload command first")
    factory, filler = chain.contract_id("vault-factory", tag), chain.contract_id("aquarius-filler", tag)

    if chain.contract_code(factory):
        click.echo(f"== deploy VaultFactory: already at {factory}")
    else:
        args = [scval.to_address(admin), factory_config(net, hashes["vault"], discount_ppm)]
        sender.submit(
            "deploy VaultFactory",
            lambda b: b.append_create_contract_op(
                hashes["vault-factory"], chain.source, args, salt(tag, "vault-factory")
            ),
        )
    for relayer in relayers:
        if chain.view(factory, "is_relayer", scval.to_address(relayer)) is True:
            click.echo(f"== relayer {relayer}: already enabled")
        elif admin != chain.source:
            click.echo(f"== relayer {relayer}: not enabled; only the admin {admin} can call set_relayer")
        else:
            sender.submit(
                f"enable relayer {relayer}",
                lambda b, r=relayer: b.append_invoke_contract_function_op(
                    factory, "set_relayer", [scval.to_address(r), scval.to_bool(True)]
                ),
            )
    if chain.contract_code(filler):
        click.echo(f"== deploy AquariusFiller: already at {filler}")
    else:
        args = [scval.to_address(net.router), scval.to_bytes(hashes["vault"])]
        sender.submit(
            "deploy AquariusFiller",
            lambda b: b.append_create_contract_op(
                hashes["aquarius-filler"], chain.source, args, salt(tag, "aquarius-filler")
            ),
        )


def plain(value):
    """Contract results as comparable plain values."""
    if isinstance(value, Address):
        return value.address
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, list):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {(k.decode() if isinstance(k, bytes) else k): plain(v) for k, v in value.items()}
    return value


def do_verify(chain: Chain, wasm: dict[str, bytes], tag: str, admin: str, relayers: list[str], discount_ppm: int):
    net = chain.net
    hashes = {crate: hashlib.sha256(code).hexdigest() for crate, code in wasm.items()}
    factory, filler = chain.contract_id("vault-factory", tag), chain.contract_id("aquarius-filler", tag)
    wrong = 0

    def check(label: str, actual, expected) -> None:
        nonlocal wrong
        ok = actual == expected
        wrong += not ok
        click.echo(f"  {'ok   ' if ok else 'WRONG'}  {label:<24} {actual}" + ("" if ok else f" (expected {expected})"))

    def code_of(contract_id: str) -> str | None:
        h = chain.contract_code(contract_id)
        return h.hex() if h else None

    click.echo("== on-chain state")
    vault_uploaded = chain.code_exists(bytes.fromhex(hashes["vault"]))
    check("vault code", hashes["vault"] if vault_uploaded else None, hashes["vault"])
    check("factory code", code_of(factory), hashes["vault-factory"])
    check("filler code", code_of(filler), hashes["aquarius-filler"])
    config = plain(chain.view(factory, "config")) or {}
    expected = {
        "usdc": net.usdc,
        "xlm": net.xlm,
        "vault_wasm_hash": hashes["vault"],
        "oracle": net.oracle,
        "xlm_asset": ["Other", "XLM"],
        "usdc_asset": ["Other", "USDC"],
        "discount_ppm": discount_ppm,
        "max_price_age": MAX_PRICE_AGE,
        "min_delivery": MIN_DELIVERY,
    }
    for field, value in expected.items():
        check(f"config.{field}", config.get(field), value)
    check("admin", plain(chain.view(factory, "admin")), admin)
    for relayer in relayers:
        check(f"relayer {relayer[:8]}…", chain.view(factory, "is_relayer", scval.to_address(relayer)), True)
    check("filler.router", plain(chain.view(filler, "router")), net.router)
    check("filler.vault_wasm", plain(chain.view(filler, "vault_wasm")), hashes["vault"])
    if wrong:
        raise Fail(f"{wrong} value(s) differ")
    click.echo("== all checks passed")


# -------------------------------------------------------- cli ---------------------------------------------------------


def address(ctx, param, value):
    """Click callback: a G or C address (or a tuple of them)."""
    values = value if isinstance(value, tuple) else (value,)
    for v in values:
        if v is not None and not (StrKey.is_valid_ed25519_public_key(v) or StrKey.is_valid_contract(v)):
            raise click.BadParameter(f"{v} is not a G or C address")
    return value


def release_tag(ctx, param, value: str) -> str:
    if not value.startswith("stellar-v"):
        raise click.BadParameter("a release tag looks like stellar-v<version>")
    return value


def target_options(f):
    for option in reversed(
        [
            click.option("--network", type=click.Choice(list(NETWORKS)), required=True),
            click.option(
                "--tag", required=True, callback=release_tag, help="Pushed release tag, e.g. stellar-v0.1.0-rc.1."
            ),
            click.option(
                "--rpc-url",
                help="Stellar RPC. Default: " + ", ".join(f"{name} {n.rpc_url}" for name, n in NETWORKS.items()) + ".",
            ),
        ]
    ):
        f = option(f)
    return f


def signing_options(f):
    for option in reversed(
        [
            click.option(
                "--signer",
                type=click.Choice(["key", "mnemonic", "ledger"]),
                required=True,
                help="key: STELLAR_SECRET_KEY or a prompt. mnemonic: STELLAR_MNEMONIC or a prompt. ledger: strledger.",
            ),
            click.option(
                "--hd-path",
                type=click.IntRange(min=0),
                default=0,
                show_default=True,
                help="Account N of m/44'/148'/N' (seed phrase or Ledger).",
            ),
            click.option(
                "--hash-signing",
                is_flag=True,
                help="Ledger: sign hashes, needed for the code uploads (enable it in the Stellar app).",
            ),
            click.option(
                "--inclusion-fee", type=click.IntRange(min=100), default=1000, show_default=True, help="In stroops."
            ),
            click.option("--yes", is_flag=True, help="Mainnet: send without asking before each transaction."),
        ]
    ):
        f = option(f)
    return f


def factory_options(f):
    for option in reversed(
        [
            click.option("--admin", callback=address, help="Factory admin. Default: the deployer."),
            click.option(
                "--relayer",
                multiple=True,
                callback=address,
                help="Relayer, repeatable. Default on testnet: the deployer; required on mainnet.",
            ),
            click.option(
                "--discount-ppm",
                type=click.IntRange(0, DISCOUNT_CAP_PPM),
                default=DEFAULT_DISCOUNT_PPM,
                show_default=True,
                help="Discount against the oracle price, in ppm.",
            ),
        ]
    ):
        f = option(f)
    return f


def open_chain(network: str, rpc_url: str | None, source: str) -> Chain:
    net = NETWORKS[network]
    chain = Chain(net, rpc_url or net.rpc_url, source)
    click.echo(f"network   {network} ({rpc_url or net.rpc_url})")
    return chain


def roles(chain: Chain, network: str, admin: str | None, relayers: tuple[str, ...]) -> tuple[str, list[str]]:
    relayers = list(relayers) or ([chain.source] if network == "testnet" else [])
    if not relayers:
        raise Fail("pass --relayer (the relayer's address) on mainnet")
    return admin or chain.source, relayers


def signer_and_sender(network, rpc_url, signer, hd_path, hash_signing, inclusion_fee, yes) -> Sender:
    s = make_signer(signer, hd_path, hash_signing)
    chain = open_chain(network, rpc_url, s.public_key)
    balance = chain.balance()
    if balance is None:
        raise Fail(f"the signer {s.public_key} has no account on {network}: fund it first")
    click.echo(f"signer    {s.public_key} ({signer}, {balance} XLM)")
    return Sender(chain, s, inclusion_fee, confirm=network == "mainnet" and not yes)


class InOrder(click.Group):
    def list_commands(self, ctx):
        return list(self.commands)  # upload, deploy, verify: the order they are run in


@click.group(cls=InOrder, context_settings={"help_option_names": ["-h", "--help"], "max_content_width": 120})
def cli():
    """Deploy the Stellar-side contracts of one network from a GitHub release (tag stellar-v<version>).

    Run upload, then deploy; verify checks a deployment at any time. Every command is idempotent: what is already on
    chain is checked and skipped. The release's wasm files are used only if their build attestations verify.
    """


@cli.command(short_help="Upload the vault, factory and filler code.")
@target_options
@signing_options
def upload(network, tag, rpc_url, signer, hd_path, hash_signing, inclusion_fee, yes):
    """Upload the vault, factory and filler code.

    Uploading creates no contract; on a Ledger the uploads need --hash-signing.
    """
    sender = signer_and_sender(network, rpc_url, signer, hd_path, hash_signing, inclusion_fee, yes)
    wasm = fetch_release(tag)
    click.echo(f"release   {tag} (attestations verified)")
    do_upload(sender, wasm)


@cli.command(short_help="Deploy the factory and the filler, enable relayers, verify.")
@target_options
@signing_options
@factory_options
def deploy(network, tag, rpc_url, signer, hd_path, hash_signing, inclusion_fee, yes, admin, relayer, discount_ppm):
    """Deploy VaultFactory and AquariusFiller, enable the relayers, then verify.

    The signer is the deployer: the two addresses derive from it and the tag, so a re-run finds them again.
    """
    sender = signer_and_sender(network, rpc_url, signer, hd_path, hash_signing, inclusion_fee, yes)
    chain = sender.chain
    admin, relayers = roles(chain, network, admin, relayer)
    wasm = fetch_release(tag)
    click.echo(f"release   {tag} (attestations verified)")
    click.echo(f"factory   {chain.contract_id('vault-factory', tag)}")
    click.echo(f"filler    {chain.contract_id('aquarius-filler', tag)}")
    do_deploy(sender, wasm, tag, admin, relayers, discount_ppm)
    do_verify(chain, wasm, tag, admin, relayers, discount_ppm)


@cli.command(short_help="Check a deployment (reads only, no key).")
@target_options
@click.option("--deployer", required=True, callback=address, help="Address that ran deploy.")
@factory_options
def verify(network, tag, rpc_url, deployer, admin, relayer, discount_ppm):
    """Compare a deployment with the release and the parameters (reads only, needs no key)."""
    chain = open_chain(network, rpc_url, deployer)
    admin, relayers = roles(chain, network, admin, relayer)
    wasm = fetch_release(tag)
    click.echo(f"release   {tag} (attestations verified)")
    click.echo(f"deployer  {deployer}")
    click.echo(f"factory   {chain.contract_id('vault-factory', tag)}")
    click.echo(f"filler    {chain.contract_id('aquarius-filler', tag)}")
    do_verify(chain, wasm, tag, admin, relayers, discount_ppm)


def main() -> None:
    try:
        cli(standalone_mode=True)
    except (BaseRequestError, NotFoundError) as e:  # network trouble: no traceback, just what happened
        raise SystemExit(f"Error: {e}") from e


if __name__ == "__main__":
    main()
