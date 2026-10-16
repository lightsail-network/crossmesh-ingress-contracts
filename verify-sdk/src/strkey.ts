import { RESERVED_CONTRACTS, type Network } from "./deployments.js";
import { decodeCheck, isValid, strkeyTypes, type VersionByteName } from "./vendor/strkey.js";

// Recipient validation for deposit addresses (THREAT-MODEL DoS.8.R.1). The factory commits the recipient
// bytes as-is, so a malformed strkey yields a perfectly valid deposit address whose USDC can never be
// delivered — this check is the only gate. A recipient must be a G, M or C strkey that passes
// js-stellar-sdk's own validation (copied in ./vendor/strkey.ts), and a C recipient must not be the
// network's CctpForwarder or USDC contract.

export type RecipientType = "account" | "muxed_account" | "contract";

export type InvalidRecipientReason = "not_a_string" | "unsupported_type" | "invalid_strkey" | "reserved_contract";

export type RecipientValidation =
  | { valid: true; type: RecipientType }
  | { valid: false; reason: InvalidRecipientReason; message: string };

const RECIPIENT_TYPES: Record<VersionByteName, RecipientType> = {
  ed25519PublicKey: "account",
  med25519PublicKey: "muxed_account",
  contract: "contract",
};

/** Validate a Stellar recipient strkey (G, M or C) for `network`. Never throws. */
export function validateRecipient(recipient: unknown, network: Network): RecipientValidation {
  if (typeof recipient !== "string") return invalid("not_a_string", "recipient must be a string");
  const name = strkeyTypes[recipient.charAt(0)];
  if (!name) return invalid("unsupported_type", "recipient must be a G, M or C strkey");
  if (!isValid(name, recipient)) {
    let message = "invalid strkey";
    try {
      decodeCheck(name, recipient);
    } catch (error) {
      message = (error as Error).message;
    }
    return invalid("invalid_strkey", message);
  }
  if (name === "contract" && RESERVED_CONTRACTS[network].includes(recipient)) {
    return invalid("reserved_contract", `recipient is the ${network} CctpForwarder or USDC contract`);
  }
  return { valid: true, type: RECIPIENT_TYPES[name] };
}

/** Thrown by the address functions when the recipient fails {@link validateRecipient}. */
export class InvalidRecipientError extends Error {
  readonly reason: InvalidRecipientReason;

  constructor(reason: InvalidRecipientReason, message: string) {
    super(`invalid Stellar recipient: ${message}`);
    this.name = "InvalidRecipientError";
    this.reason = reason;
  }
}

function invalid(reason: InvalidRecipientReason, message: string): RecipientValidation {
  return { valid: false, reason, message };
}
