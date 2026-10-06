# Bridge test properties

Run `forge build` and `forge test` from the repository root. All dependencies are
already ordinary repository files; the new tests need no network, fork, FFI or
environment changes. They extend the existing configuration/send/receive tests.

## Stateful custody model

`AdapterInvariant.t.sol` targets only the ten actions in `handlers/BridgeHandler.sol`.
Three actors send, receive, transfer tokens between themselves, donate ZTO, attempt
unauthorized calls, and trigger failed sends/receives and replay attempts. Amounts
include zero, one wei, sub-shared-unit dust, one shared unit, full balances and bounded
random values. Delivery is a separate action and can happen out of order.

The model tracks expected user balances and pending claims from requested amounts,
not from the adapter's return values. The following properties are checked after
random calls:

- Escrow equals remote supply plus pending outbound mints plus pending inbound
  releases plus donations. Independently, it equals cumulative locks minus releases
  plus donations, and cumulative releases cannot exceed locks.
- Each user's home and remote balance matches that user's modeled debits, credits,
  transfers and donations. The existing ZTO supply is unchanged. Spendable home
  tokens, remote tokens, in-flight claims and donations sum to the initial supply.
- Unauthorized callers cannot alter owner, delegate or peer configuration. Native
  send fees reach the relevant endpoint and do not accumulate in the adapter.

Failure actions check rollback of balances, allowances, fees and messaging state;
failed inbound packets retain their pending claim. Peer removal is temporary in
this handler so subsequent retry and redemption remain meaningful. The separate
adversarial tests also exercise peer replacement with an in-flight message.

After every random sequence, `afterInvariant` delivers outstanding packets,
consolidates remote dust between actors and redeems all remote supply. Custody must
then contain exactly the recorded donations. This checks redeemability as well as
accounting. A deterministic test exercises every handler action, both receive
failure branches and the final drain.

Inline settings select 256 invariant runs at depth 64 with `fail-on-revert = true`.
Expected rejection paths use explicit `expectRevert`; unexpected reverts are not
silently discarded. Each campaign starts with nonzero circulating supply and queued
messages in both directions.

## Arithmetic and failure boundaries

`AdapterAdversarial.t.sol` adds five 1,000-run fuzz properties for full-range shared
amount round trips, slippage after rounding, truncated receive payloads, arbitrary
untrusted peers and arbitrary non-endpoint callers. Explicit examples cover one
wei, one shared unit, the entire initial supply, `uint64.max` shared units plus dust,
`uint256.max` overflow, and six-/nine-decimal local tokens.

Other cases check refund rejection after a packet is queued, unavailable approval
or false returns from the LayerZero fee token, late endpoint failure after both
ERC20 debits, replacement of peers with messages pending, and atomic rejection of
an invalid options batch.

## Model boundaries

The tests exercise the actual adapter and vendored OFT contracts against the existing
lossless token mock and local transport mock. The mock endpoint supplies verified,
queued, at-most-once delivery. Replay assertions test that modeled integration;
they do not establish the real endpoint's verification or replay security.

No live ZTO bytecode or transfer behavior is established by these tests. The alternate
decimal cases test conversion behavior, not the deployed token's actual decimals.
The model assumes lossless transfers, a remote OFT with no independent minting, and
honest authorized messaging. Direct donations create no remote claims and remain
in custody after settlement because the application has no rescue function.
