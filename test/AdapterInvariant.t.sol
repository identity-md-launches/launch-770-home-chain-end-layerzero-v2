// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {BridgeHandler} from "./handlers/BridgeHandler.sol";

/// @dev Runs through the public adapter API and the actual vendored OFT on the remote side.
/// The endpoint mock models authenticated, asynchronous, at-most-once delivery; it does not
/// establish the security of DVNs, ULN libraries, or a production remote deployment.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AdapterInvariantTest is BridgeTestBase {
    address private constant CHARLIE = address(0xCA11);
    BridgeHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(ALICE);
        zto.transfer(BOB, 300_000 ether);
        zto.transfer(CHARLIE, 300_000 ether);
        vm.stopPrank();
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CHARLIE, 100 ether);
        handler = new BridgeHandler(adapter, zto, remoteOFT, home, remote, [ALICE, BOB, CHARLIE]);

        // Every campaign begins with real custody, circulating tokens and packets in both
        // directions, so receive/retry handlers are reachable even before a random send.
        handler.sendOut(0, 1, 4);
        handler.deliverOut(0);
        handler.sendBack(1, 2, 3, true);
        handler.sendOut(1, 2, 4);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.sendOut.selector;
        selectors[1] = handler.deliverOut.selector;
        selectors[2] = handler.sendBack.selector;
        selectors[3] = handler.deliverBack.selector;
        selectors[4] = handler.transferBetweenUsers.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.rejectedSend.selector;
        selectors[7] = handler.rejectedReceive.selector;
        selectors[8] = handler.unauthorizedCalls.selector;
        selectors[9] = handler.replayLastReceive.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev Exact accounting identity: an outbound lock backs either a pending mint, a live
    /// remote token, or a pending release. Donations create surplus, not remote claims.
    function invariant_custodyBacksCirculationAndBothMessageQueues() public view {
        assertEq(
            zto.balanceOf(address(adapter)),
            remoteOFT.totalSupply() + handler.outboundValue() + handler.inboundValue() + handler.donated()
        );
        assertLe(handler.released(), handler.locked(), "released more than locked");
        assertEq(zto.balanceOf(address(adapter)), handler.locked() - handler.released() + handler.donated());
    }

    function invariant_eachUserReceivesExactlyTheirOwnTransfers() public view {
        uint256 homeBalances;
        uint256 remoteBalances;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(zto.balanceOf(actor), handler.expectedHome(i), "wrong home beneficiary or amount");
            assertEq(remoteOFT.balanceOf(actor), handler.expectedRemote(i), "wrong remote beneficiary or amount");
            homeBalances += zto.balanceOf(actor);
            remoteBalances += remoteOFT.balanceOf(actor);
        }
        assertEq(remoteBalances, remoteOFT.totalSupply());
        assertEq(homeBalances + zto.balanceOf(address(adapter)), SUPPLY);
        assertEq(
            homeBalances + remoteBalances + handler.outboundValue() + handler.inboundValue() + handler.donated(),
            SUPPLY,
            "economic supply changed"
        );
        assertEq(zto.totalSupply(), SUPPLY, "adapter minted or burned existing ZTO");
    }

    function invariant_authoritiesAndNativeFeesRemainCorrect() public view {
        assertEq(adapter.owner(), OWNER);
        assertEq(home.delegates(address(adapter)), OWNER);
        assertEq(adapter.peers(REMOTE_EID), _b32(address(remoteOFT)));
        assertEq(adapter.peers(HOME_EID), bytes32(0));
        assertEq(adapter.peers(0), bytes32(0));
        assertEq(address(adapter).balance, 0, "native send fee retained");
        assertEq(address(home).balance, handler.sends() * NATIVE_FEE);
        assertEq(address(remote).balance, handler.burns() * NATIVE_FEE);
        assertEq(adapter.sharedDecimals(), 6);
    }

    /// @dev Checks liveness after every campaign: all queued messages and remote balances can
    /// settle, including ones that previously failed. Only unsolicited donations remain locked.
    function afterInvariant() public {
        handler.drain();
        invariant_custodyBacksCirculationAndBothMessageQueues();
        invariant_eachUserReceivesExactlyTheirOwnTransfers();
        invariant_authoritiesAndNativeFeesRemainCorrect();
        assertEq(handler.outboundValue(), 0);
        assertEq(handler.inboundValue(), 0);
        assertEq(handler.locked(), handler.released());
    }

    function test_handlerExercisesFailuresTransfersDonationsAndDrain() public {
        handler.rejectedSend(2, 4);
        handler.rejectedReceive(0, false);
        handler.rejectedReceive(0, true);
        handler.unauthorizedCalls(2, type(uint256).max);
        handler.deliverBack(0);
        handler.replayLastReceive();
        handler.deliverOut(0);
        handler.transferBetweenUsers(2, 0, 1, true); // Split one wei of remote dust.
        handler.transferBetweenUsers(1, 2, 4, true);
        handler.transferBetweenUsers(2, 1, 1, false);
        handler.donate(2, 3);
        handler.sendBack(2, 0, 4, true);
        invariant_custodyBacksCirculationAndBothMessageQueues();
        invariant_eachUserReceivesExactlyTheirOwnTransfers();
        assertEq(handler.rejectedCalls(), 5);
        assertGt(handler.donated(), 0);
        assertGt(handler.locked(), 0);
        afterInvariant();
        assertGt(handler.credits(), 0);
    }
}
