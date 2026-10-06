# ZTO Ethereum OFT adapter

`src/ZTOAdapter.sol` is the home-chain custody contract for the existing Zero To One ERC20. It inherits the vendored LayerZero V2 `OFTAdapter`: sending locks approved ZTO in the adapter, and receiving a verified message from its configured Robinhood peer releases ZTO. It does not mint or burn the Ethereum token.

The only application contract to deploy is **ZTOAdapter**, with **no constructor arguments** and **zero deployment value**. All dependencies are ordinary source files; nothing is installed under `lib/` or downloaded during compilation or testing.

## Build and test

With Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Paris EVM, optimizer runs 200, and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are not enabled. Build output and cache go under disposable `test/scratch/`; deleting that directory is safe. Vendored code is excluded from formatting to retain the upstream file hashes.

## Deployment parameters

| Parameter | Fixed value |
| --- | --- |
| Deployment chain | Ethereum mainnet, chain ID 1 |
| Existing ZTO | `0xd782bdea4ef02a0bd391eb9089470c8080f0a68e` |
| EndpointV2 | `0x1a44076050125825900e736c501f859c50fE728c` |
| Ethereum endpoint ID | `30101` |
| Sole supported remote endpoint ID | `30416` (Robinhood) |
| Initial owner and LayerZero delegate | `0xcecc29b037f5064fcdf45a5c318f132ef76aa551` |
| Shared decimals | `6` |
| Constructor arguments | `[]` |
| Constructor ETH value | `0` |

The constructor reads ZTO's `decimals()` and calls `EndpointV2.setDelegate` for the new adapter. The explicit owner is independent of `msg.sender`, including deployment through a factory. The token and endpoint are immutable. The contract is intended only for Ethereum; it does not infer the chain from `block.chainid` or select other addresses automatically.

The Robinhood OFT address has not been supplied and is not invented here. The adapter starts with no peer. Only the current owner can call `setPeer`, and only for EID 30416. For an EVM peer, the owner supplies `bytes32(uint256(uint160(robinhoodOFT)))`. `bytes32(0)` removes the peer. The remote OFT must separately trust this adapter at EID 30101. These operational wiring calls are required before bridging can work.

The remote OFT must use compatible OFT message version 1 and six shared decimals, burn on outbound transfers, and mint only for authenticated inbound transfers. Start its supply at zero. There must be only one custody adapter for this token's bridge network. The test-only `RemoteOFT` is a local compatibility fixture, not a Robinhood deployment deliverable.

## Transfer behavior

The implementation follows [LayerZero's OFT adapter standard](https://docs.layerzero.network/v2/developers/evm/oft/quickstart). The application wrapper adds only fixed deployment parameters and the restriction to Robinhood's EID. Versions and source checksums are recorded in [the dependency manifest](src/vendor/DEPENDENCIES.json).

1. Build a `SendParam` with `dstEid = 30416`, the recipient as a left-zero-padded EVM address in `bytes32`, and the amount in ZTO's local units. Validate the recipient; the standard codec does not reject a zero address or nonzero high address bytes. Leave `oftCmd` empty; the standard implementation does not use it.
2. Read `decimalConversionRate()`. It is `10 ** (ZTO.decimals() - 6)`. The debited amount is rounded down to a multiple of this rate; dust stays with the sender. `minAmountLD` applies after rounding. For example, if local decimals are 18, the rate is `10**12`.
3. Inspect `quoteOFT`, then approve the adapter to spend the intended rounded ZTO amount. `approvalRequired()` is true. Approval of an exact amount limits exposure. `quoteOFT` is an informational quote: it does not check allowance, balance, peer configuration or all endpoint constraints. Its reported maximum is token total supply, while message encoding is separately limited to `uint64` shared units.
4. Get a fresh `quoteSend(param, false)` and call `send(param, fee, refundAddress)` with `msg.value == fee.nativeFee`. Supply valid executor options or use options enforced by the owner. The endpoint returns excess native payment to `refundAddress`. Optional LZ-token fee payment is inherited and requires allowance for that fee token as well.
5. Track the returned GUID and `OFTSent`/`OFTReceived` events. Sending and destination delivery are separate transactions. A successful send does not mean the recipient has already been credited.

There is no application fee: the rounded amount locked equals the amount represented in the remote message. LayerZero messaging/execution fees still apply. Amounts exceeding `uint64.max` shared units revert instead of truncating. Zero or dust-only sends with a zero minimum are allowed by the standard and can still consume messaging fees; clients should filter those out.

On return, the remote OFT burns tokens and sends a message to Ethereum. The adapter authenticates both the local endpoint caller and the configured source peer before releasing custody. EndpointV2 provides message verification and replay protection; the adapter does not maintain a second replay table. Ordered execution is not enabled (`nextNonce` returns zero).

If a token transfer, native payment, inspector, or endpoint send reverts, the entire source transaction rolls back, including the token lock and allowance change. A destination execution failure leaves the verified message available for retry under EndpointV2 semantics. Do not treat a delayed transfer as a refund entitlement or manually mint replacement remote tokens.

Standard composed transfers are supported: the adapter credits ZTO, then queues the OFT compose payload using `sendCompose`. The separate composer executes later. A compose-queue failure rolls back the receive; a later composer failure does not undo the already completed token credit. Composers require their own authentication, implementation review, and executor gas options.

## Assumptions and operator responsibilities

- **Token behavior:** ZTO must have stable decimals of at least six, lossless ERC20 transfers, no transfer tax or rebasing, and no unexpected transfer callbacks. This is the standard OFTAdapter assumption. The contract reads local decimals rather than assuming 18. Tests use a lossless 18-decimal mock at the specified address. A public Ethereum RPC read attempt was rejected and the source lookup was unavailable, so live token code, decimals, transfer behavior, and administrative powers have not been independently verified here. Verify these before deployment; do not activate this adapter for a fee-on-transfer or rebasing token.
- **Custody backing:** remote circulating supply plus all in-flight transfers must remain backed by Ethereum escrow, accounting for delivery direction. Direct transfers to the adapter do not create bridge messages or remote claims. Such donations and accidentally sent assets cannot be rescued.
- **Trusted configuration:** the owner can replace/remove the Robinhood peer, change the delegate, enforce options, set a message inspector, and configure PreCrime. A malicious peer or compromised messaging configuration can authorize release of all escrow. Removing/replacing peers can block pending messages, so plan configuration changes around in-flight traffic.
- **Ownership and delegation:** standard Ownable transfer/renunciation functions remain. Transferring ownership does not change EndpointV2's delegate. Rotate the two authorities deliberately and verify both. Renouncing ownership leaves any existing endpoint delegate in place and removes access to owner-only application configuration.
- **Messaging security:** the delegate must choose and verify compatible send/receive libraries, DVNs and thresholds, block confirmations, executor settings, and gas options for both directions. These values and the actual remote address are unresolved operational choices. Configure and check explicit settings rather than assuming endpoint defaults are suitable. Validate real gas usage for message types 1 (`SEND`) and 2 (`SEND_AND_CALL`).
- **Hooks:** the optional inspector and PreCrime addresses default to zero. Inspectors must revert on rejection; the upstream OFT ignores their boolean return. The simulation entry point always reverts and cannot retain transferred assets. Set hooks only after separate review.
- **Administrative limits:** there is no dedicated pause, fee setter, upgrade path, rescue, or owner withdrawal function. The inherited peer/configuration controls can nevertheless block traffic. Arbitrary custody withdrawals are not provided, and mistakes cannot be repaired with an upgrade.
- **Native value:** ordinary sends forward their native fee. Do not attach native value to incoming execution options for this adapter; its receive logic has no native-value payout. Forced ETH or native value delivered with a receive cannot be rescued.
- **Operations:** verify deployed bytecode and constructor state on Ethereum, wire and validate both peers, perform small transfers in both directions, monitor GUIDs and escrow against remote liabilities, and retry failed executions after resolving their cause. Review the remote OFT and its administrative powers together with this adapter before enabling funds.

No transaction was broadcast and no wallet keys were used. Deployment and cross-chain activation remain the operator's responsibility.

## Validation and review limits

The local suite has 46 tests, including two 256-case fuzz tests. It covers factory ownership/delegation, peer restrictions, authorization of inherited configuration, packet encoding, dust/slippage and `uint64` boundaries, token approval and balances, round-trip conservation, fee payment/refunds, source rollback, source-peer authentication, malformed receives, receive retries, unordered delivery, compose encoding/rollback, and simulation isolation. It also checks deployed runtime size and scans runtime instructions for the forbidden `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT` opcodes.

Endpoint and token mocks isolate contract behavior without network or environment variables. Mock replay/queue tests demonstrate the adapter's integration expectations; they do not test actual DVN signatures, ULN verification, the real executor, or the live ZTO contract. The supplied protected harness requires deployment environment inputs; the local runtime/factory checks cover the applicable mechanics without fabricating those inputs.

With the pinned build settings, ZTOAdapter's runtime is 11,631 bytes and its creation bytecode is 12,649 bytes, below the respective 24,576/49,152-byte limits. Foundry's build linter reports warnings in upstream source. Review of those warnings is recorded in [SECURITY.md](SECURITY.md). Slither and Mythril were not run. These checks are not an independent security audit; the custody contract, remote OFT, and deployment configuration need an independent adversarial review before release.
