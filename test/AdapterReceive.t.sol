// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {EndpointMock} from "./mocks/EndpointMock.sol";
import {MessagingReceipt, IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {
    IOAppPreCrimeSimulator,
    InboundPacket
} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AdapterReceiveTest is BridgeTestBase {
    function test_receiveReleasesCustodyAndEmitsReceipt() public {
        _bridgeOut(9 ether);
        MessagingReceipt memory receipt = _sendBack(4 ether, "");
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IOFT.OFTReceived(receipt.guid, REMOTE_EID, ALICE, 4 ether);
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 5 ether);
        assertEq(zto.balanceOf(address(adapter)), 5 ether);
        assertEq(remoteOFT.balanceOf(BOB), 5 ether);
        assertEq(zto.totalSupply(), SUPPLY);
    }

    function test_directReceiveCannotUnlockEvenWithCorrectOrigin() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, BOB));
        vm.prank(BOB);
        adapter.lzReceive(origin, bytes32(uint256(1)), _payload(1 ether), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_endpointWithWrongPeerCannotUnlock() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(REMOTE_EID, _b32(BOB), 1);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, REMOTE_EID, _b32(BOB)));
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), _payload(1 ether), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_endpointWithWrongSourceChainCannotUnlock() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(30110, _b32(address(remoteOFT)), 1);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(30110)));
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), _payload(1 ether), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_removedPeerBlocksPendingMessageUntilRestored() public {
        _bridgeOut(1 ether);
        MessagingReceipt memory receipt = _sendBack(1 ether, "");
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        EndpointMock.Packet memory p = remote.packet(receipt.guid);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, REMOTE_EID));
        home.deliver(p.origin, p.receiver, receipt.guid, p.message);
        assertFalse(home.delivered(receipt.guid));
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(address(remoteOFT)));
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
    }

    function test_falseTransferReturnPreservesPacketForRetry() public {
        _bridgeOut(1 ether);
        MessagingReceipt memory receipt = _sendBack(1 ether, "");
        EndpointMock.Packet memory p = remote.packet(receipt.guid);
        zto.setFailures(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN));
        home.deliver(p.origin, p.receiver, receipt.guid, p.message);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertFalse(home.delivered(receipt.guid));
        assertNotEq(home.pending(receipt.guid), bytes32(0));
        zto.setFailures(false, false);
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertTrue(home.delivered(receipt.guid));
    }

    function test_insufficientCustodyRevertsWithoutMinting() public {
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, 1 ether)
        );
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), _payload(1 ether), BOB, "");
        _assertNoLock();
    }

    function test_shortPayloadRevertsWithoutUnlocking() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert();
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), abi.encodePacked(_b32(ALICE)), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
    }

    function test_zeroRecipientRevertsAccordingToUnderlyingERC20() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), abi.encodePacked(bytes32(0), uint64(1_000_000)), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_transportRejectsReplayAndModifiedPacket() public {
        // Replay verification is an EndpointV2 responsibility, modeled here by the mock queue.
        _bridgeOut(2 ether);
        MessagingReceipt memory receipt = _sendBack(1 ether, "");
        EndpointMock.Packet memory p = remote.packet(receipt.guid);
        vm.expectRevert(EndpointMock.InvalidPacket.selector);
        home.deliver(p.origin, p.receiver, receipt.guid, _payload(2 ether));
        _deliver(remote, home, receipt.guid);
        vm.expectRevert(EndpointMock.InvalidPacket.selector);
        home.deliver(p.origin, p.receiver, receipt.guid, p.message);
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
    }

    function test_unorderedDeliveryConservesCustody() public {
        _bridgeOut(5 ether);
        MessagingReceipt memory first = _sendBack(2 ether, "");
        MessagingReceipt memory second = _sendBack(3 ether, "");
        assertEq(adapter.nextNonce(REMOTE_EID, _b32(address(remoteOFT))), 0);
        _deliver(remote, home, second.guid);
        assertEq(zto.balanceOf(address(adapter)), 2 ether);
        _deliver(remote, home, first.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(remoteOFT.totalSupply(), 0);
    }

    function test_receiveWithComposeCreditsAndQueuesStandardComposePayload() public {
        _bridgeOut(3 ether);
        MessagingReceipt memory receipt = _sendBack(3 ether, hex"cafe");
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(home.lastComposeFrom(), address(adapter));
        assertEq(home.lastComposeTo(), ALICE);
        assertEq(home.lastComposeGuid(), receipt.guid);
        assertEq(home.lastComposeIndex(), 0);
        assertEq(
            home.lastComposeMessage(),
            abi.encodePacked(receipt.nonce, REMOTE_EID, uint256(3 ether), _b32(BOB), hex"cafe")
        );
    }

    function test_composeQueueFailureRollsBackCreditThenAllowsRetry() public {
        _bridgeOut(3 ether);
        MessagingReceipt memory receipt = _sendBack(3 ether, hex"cafe");
        EndpointMock.Packet memory p = remote.packet(receipt.guid);
        home.setFailures(false, true);
        vm.expectRevert(EndpointMock.ComposeRejected.selector);
        home.deliver(p.origin, p.receiver, receipt.guid, p.message);
        assertEq(zto.balanceOf(address(adapter)), 3 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 3 ether);
        assertFalse(home.delivered(receipt.guid));
        home.setFailures(false, false);
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
    }

    function test_simulationEntryPointCannotBeCalledDirectly() public {
        _bridgeOut(1 ether);
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(IOAppPreCrimeSimulator.OnlySelf.selector);
        adapter.lzReceiveSimulate(origin, bytes32(uint256(1)), _payload(1 ether), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_simulationAlwaysRevertsAndCannotKeepUnlockedTokens() public {
        _bridgeOut(1 ether);
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = InboundPacket({
            origin: Origin(REMOTE_EID, _b32(address(remoteOFT)), 1),
            dstEid: HOME_EID,
            receiver: address(adapter),
            guid: bytes32(uint256(1)),
            value: 0,
            executor: BOB,
            message: _payload(1 ether),
            extraData: ""
        });
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, abi.encode(SUPPLY)));
        adapter.lzReceiveAndRevert(packets);
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
    }

    function buildSimulationResult() external view returns (bytes memory) {
        return abi.encode(zto.balanceOf(ALICE));
    }

    function _payload(uint256 amount) private pure returns (bytes memory) {
        return abi.encodePacked(_b32(ALICE), uint64(amount / RATE));
    }
}
