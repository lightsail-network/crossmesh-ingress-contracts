import { sha256 } from "@noble/hashes/sha2.js";
import { ascii, concat } from "./bytes.js";
import { toBase32 } from "./vendor/base32.js";
import { decodeCheck } from "./vendor/strkey.js";

// Soroban address derivation, hand-rolled so the package stays free of a Stellar dependency.
//
//   contract id = sha256( HashIdPreimage::ENVELOPE_TYPE_CONTRACT_ID { network_id, preimage } )
//   network_id  = sha256(passphrase)
//   preimage    = ContractIdPreimage::Address { address, salt }   (contracts deployed by a contract)

// XDR discriminants (stellar-xdr: Stellar-ledger-entries.x / Stellar-transaction.x).
const ENVELOPE_TYPE_CONTRACT_ID = 8;
const CONTRACT_ID_PREIMAGE_FROM_ADDRESS = 0;
const SC_ADDRESS_TYPE_CONTRACT = 1;
/** Strkey version byte of a contract address (`C`). */
const CONTRACT_VERSION_BYTE = 2 << 3;

/** The address of the contract that `deployer` (a contract, C strkey) deploys with `salt` on `passphrase`. */
export function deriveContractAddress(deployer: string, salt: Uint8Array, passphrase: string): string {
  const preimage = concat(
    be32(ENVELOPE_TYPE_CONTRACT_ID),
    sha256(ascii(passphrase)),
    be32(CONTRACT_ID_PREIMAGE_FROM_ADDRESS),
    be32(SC_ADDRESS_TYPE_CONTRACT),
    decodeCheck("contract", deployer),
    salt,
  );
  return encodeContract(sha256(preimage));
}

/** Strkey-encode a 32-byte contract id: version byte ‖ payload ‖ CRC16-XMODEM (little-endian), base32. */
export function encodeContract(contractId: Uint8Array): string {
  const body = concat(Uint8Array.of(CONTRACT_VERSION_BYTE), contractId);
  let crc = 0;
  for (const byte of body) {
    crc ^= byte << 8;
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return toBase32(concat(body, Uint8Array.of(crc & 0xff, crc >> 8)));
}

function be32(value: number): Uint8Array {
  return Uint8Array.of((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
}
