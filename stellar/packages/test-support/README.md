# `test-support`

Test-only helpers. The Soroban test environment does not create classic ledger entries on demand, so
these create accounts and trustlines, deploy the real native XLM contract (for account creation) and
check whether a contract instance exists.
