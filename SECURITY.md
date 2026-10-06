# Local security review

This implementation keeps LayerZero's OFTAdapter/OApp code unmodified. `ZTOAdapter` fixes the token, endpoint, initial owner and delegate, and restricts peer configuration to EID 30416. No generic external-call facility, proxy, rescue, or application withdrawal is added. Only this wrapper is the production application.

## Reviewed boundaries

- `_send` always debits `msg.sender`; its caller cannot specify an arbitrary token holder. `SafeERC20` handles transfer failure and false returns. Tokens are locked before dispatch and any subsequent failure rolls back that lock.
- The receive entry point requires the fixed endpoint caller and the configured peer for the source EID. These checks precede custody release. The endpoint is responsible for payload verification and replay prevention.
- Local/shared decimal conversion removes dust before locking and checks the `uint64` bound before message encoding. No conversion-dependent token amount is inferred from an address or arbitrary byte field.
- Token and endpoint external calls rely on the fixed trusted dependencies behaving as specified. The default OFTAdapter does not add a reentrancy guard. There is no per-user claim ledger to expose through stale updates; each send debits its own caller, and endpoint verification protects inbound execution. This assessment depends on lossless, non-rebasing ZTO behavior, not on a promise about arbitrary ERC20s. Fee refund callbacks can reenter as their own caller, so event ordering alone is not proof of message settlement.
- Only the owner can set peers, options, inspectors, PreCrime or the endpoint delegate. Owner replacement of the peer is a custody trust boundary even though no withdrawal method exists.
- `lzReceiveSimulate` is self-call only. `lzReceiveAndRevert` rolls back all simulated credits at completion. Neither creates a withdrawal path.

## Foundry lint warnings in upstream code

The build succeeds with these source-level warnings left visible; vendored files have not been edited to suppress them.

| Warning group | Assessment for this application |
| --- | --- |
| `Address.functionDelegateCall` | Unused library utility. It is eliminated from the deployed adapter. The runtime opcode scan passes. |
| Arbitrary ERC20 sender | OFTAdapter's internal `_debit` receives `msg.sender` from `_send`. A test confirms another caller cannot spend Alice's allowance. |
| Divide before multiply | Intentional downward rounding to shared-decimal precision; the rounded-away dust remains with the sender. |
| Narrow integer casts | OFT `_toSD` explicitly rejects values above `uint64.max`. Address codecs intentionally translate between EVM and bytes32 addresses; integrations must validate recipient encoding. |
| Ignored inspector return | Upstream contract requires inspectors to revert on rejection. Returning false alone is insufficient. The rejection/rollback path is tested. |
| Missing zero check for hooks | Zero disables the optional inspector/PreCrime setting. Both setters are owner-only. |
| Calls/reverts inside loops | Owner-configured options are validated atomically; PreCrime simulation loops deliberately revert. Neither loop pays persistent withdrawals. |
| Events after calls | Standard OFT receipt events follow token/endpoint success. Indexers should track endpoint GUIDs and receipts, and tolerate callback-related ordering. |
| Locked ETH | Normal sends forward native fees, and simulations revert. Native value supplied on receive or forced into the contract remains stuck because no rescue is requested. Operators must configure incoming executor value as zero. |

## Remaining external review

Validate the actual ZTO bytecode, decimals, tax/rebase/callback behavior and token administrative powers. Verify Ethereum's endpoint and the Robinhood route. Independently review the remote OFT, its initial supply, peer configuration, any mint powers, owner/delegate custody and chosen messaging security stack. Exercise real asynchronous retries and gas settings before allowing material bridge volume.

The local unit/fuzz suite does not model compromised DVNs, endpoint governance, a malicious peer, or token upgrades. Any of those trusted dependencies can invalidate the backing assumptions. No Slither, Mythril, live fork integration or independent contributor audit was performed in this assignment.
