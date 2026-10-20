import { decodeCheck, isValid, strkeyTypes } from "./vendor/strkey.js";

// Recipient validation (THREAT-MODEL DoS.8.R.1). The factory commits the recipient bytes as-is, so a
// malformed strkey yields a perfectly valid deposit address whose USDC can never be delivered — this check
// is the only gate. A recipient must be a G, M or C strkey that passes js-stellar-sdk's own validation
// (copied in ./vendor/strkey.ts). Which valid address receives the funds is the user's decision, so no valid
// address is refused for what it is.

/** Thrown when a recipient is not a valid Stellar G, M or C address; `message` says why. */
export class InvalidRecipientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvalidRecipientError";
  }
}

/** Whether `recipient` is a valid Stellar G (account), M (muxed account) or C (contract) address. Never throws. */
export function isValidRecipient(recipient: unknown): boolean {
  return recipientError(recipient) === null;
}

/**
 * @internal
 * @throws InvalidRecipientError, with the decoder's reason, unless {@link isValidRecipient}.
 */
export function checkRecipient(recipient: unknown): asserts recipient is string {
  const message = recipientError(recipient);
  if (message !== null) throw new InvalidRecipientError(message);
}

/** Why `recipient` is not a valid G, M or C address; null if it is. */
function recipientError(recipient: unknown): string | null {
  if (typeof recipient !== "string") return "recipient must be a string";
  const name = strkeyTypes[recipient.charAt(0)];
  if (!name) return "recipient must be a Stellar G, M or C address";
  if (isValid(name, recipient)) return null;
  try {
    decodeCheck(name, recipient);
  } catch (error) {
    return `recipient is not a valid strkey: ${(error as Error).message}`;
  }
  return "recipient is not a valid strkey";
}
