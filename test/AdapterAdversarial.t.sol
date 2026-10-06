// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {EndpointMock} from "./mocks/EndpointMock.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    EnforcedOptionParam,
    IOAppOptionsType3
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

contract RejectNativeRefund {
    receive() external payable {
        revert("refund rejected");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract AdapterAdversarialTest is BridgeTestBase {
    function testFuzz_roundTripAcrossSharedAmountDomain(uint64 units, uint256 dustSeed) public {
        uint256 dust = bound(dustSeed, 0, RATE - 1);
        _roundTrip(units, dust);
    }

    function test_oneWeiNeverCreatesARemoteClaim() public {
        _roundTrip(0, 1);
    }

    function test_oneSharedUnitRoundTrips() public {
        _roundTrip(1, 0);
    }

    function test_fullSupplyRoundTrips() public {
        _roundTrip(uint64(SUPPLY / RATE), 0);
    }

    function test_maximumSharedAmountPlusDustRoundTrips() public {
        _roundTrip(type(uint64).max, RATE - 1);
    }

    function _roundTrip(uint64 units, uint256 dust) private {
        uint256 bridged = uint256(units) * RATE;
        uint256 requested = bridged + dust;
        if (requested > SUPPLY) zto.mint(ALICE, requested - SUPPLY);
        uint256 initial = zto.balanceOf(ALICE);
        SendParam memory p = _param(REMOTE_EID, BOB, requested, bridged);
        (,, OFTReceipt memory quote) = adapter.quoteOFT(p);
        vm.startPrank(ALICE);
        // Only the bridgeable amount needs approval, even when the request includes dust.
        zto.approve(address(adapter), bridged);
        (MessagingReceipt memory receipt, OFTReceipt memory actual) =
            adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        vm.stopPrank();
        assertEq(actual.amountSentLD, bridged);
        assertEq(actual.amountReceivedLD, bridged);
        assertEq(actual.amountSentLD, quote.amountSentLD);
        assertEq(actual.amountReceivedLD, quote.amountReceivedLD);
        assertEq(zto.balanceOf(ALICE), initial - bridged);
        assertEq(zto.balanceOf(address(adapter)), bridged);
        assertEq(zto.allowance(ALICE, address(adapter)), 0);
        EndpointMock.Packet memory packet = home.packet(receipt.guid);
        assertEq(packet.message, abi.encodePacked(_b32(BOB), units));
        _deliver(home, remote, receipt.guid);
        assertEq(remoteOFT.balanceOf(BOB), bridged);
        MessagingReceipt memory back = _sendBack(bridged, "");
        _deliver(remote, home, back.guid);
        assertEq(zto.balanceOf(ALICE), initial, "round trip lost or created value");
        assertEq(zto.totalSupply(), initial);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(remoteOFT.totalSupply(), 0);
    }

    function testFuzz_minimumAboveRoundedAmountRejectsQuoteAndSend(uint64 units, uint256 dustSeed) public {
        uint256 dust = bound(dustSeed, 1, RATE - 1);
        uint256 bridged = uint256(units) * RATE;
        uint256 requested = bridged + dust;
        SendParam memory p = _param(REMOTE_EID, BOB, requested, bridged + 1);
        bytes memory reason = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, bridged, bridged + 1);
        vm.expectRevert(reason);
        adapter.quoteOFT(p);
        vm.expectRevert(reason);
        adapter.quoteSend(p, false);
        vm.prank(ALICE);
        zto.approve(address(adapter), requested);
        vm.expectRevert(reason);
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        _assertNoLock();
        assertEq(zto.allowance(ALICE, address(adapter)), requested);
        assertEq(ALICE.balance, 10 ether);
    }

    function test_uint256MaximumCannotTruncateIntoAValidPacket() public {
        uint256 requested = type(uint256).max;
        zto.mint(ALICE, requested - SUPPLY);
        SendParam memory p = _param(REMOTE_EID, BOB, requested, 0);
        bytes memory reason = abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, requested / RATE);
        vm.expectRevert(reason);
        adapter.quoteSend(p, false);
        vm.prank(ALICE);
        zto.approve(address(adapter), requested);
        vm.expectRevert(reason);
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        assertEq(zto.balanceOf(ALICE), requested);
        assertEq(zto.totalSupply(), requested);
        assertEq(zto.allowance(ALICE, address(adapter)), requested);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(home.lastGuid(), bytes32(0));
    }

    function test_rejectedRefundRollsBackQueueNonceLockAndFeePayment() public {
        RejectNativeRefund rejector = new RejectNativeRefund();
        SendParam memory p = _param(REMOTE_EID, BOB, 2 ether, 2 ether);
        bytes32 path = keccak256(abi.encode(address(adapter), REMOTE_EID, _b32(address(remoteOFT))));
        bytes32 expectedGuid =
            keccak256(abi.encode(uint64(1), HOME_EID, address(adapter), REMOTE_EID, _b32(address(remoteOFT))));
        vm.prank(ALICE);
        zto.approve(address(adapter), 2 ether);
        vm.expectRevert(EndpointMock.RefundFailed.selector);
        vm.prank(ALICE);
        adapter.send{value: 2 * NATIVE_FEE}(p, MessagingFee(2 * NATIVE_FEE, 0), address(rejector));
        _assertNoLock();
        assertEq(zto.allowance(ALICE, address(adapter)), 2 ether);
        assertEq(ALICE.balance, 10 ether);
        assertEq(ENDPOINT.balance, 0);
        assertEq(address(adapter).balance, 0);
        assertEq(home.outboundNonce(path), 0);
        assertEq(remote.pending(expectedGuid), bytes32(0));
        EndpointMock.Packet memory absent = home.packet(expectedGuid);
        assertEq(absent.message.length, 0);
        vm.prank(ALICE);
        (MessagingReceipt memory receipt,) = adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        assertEq(receipt.nonce, 1);
        assertEq(receipt.guid, expectedGuid);
        _deliver(home, remote, receipt.guid);
        assertEq(zto.balanceOf(address(adapter)), 2 ether);
        assertEq(remoteOFT.balanceOf(BOB), 2 ether);
    }

    function test_feeTokenWithoutAllowanceRollsBackZTOLock() public {
        MockZTO feeToken = _feeToken();
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.prank(ALICE);
        zto.approve(address(adapter), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, 10 ether)
        );
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 10 ether), ALICE);
        _assertFeeRollback(feeToken, 0);
    }

    function test_falseFeeTokenTransferRollsBackZTOLock() public {
        MockZTO feeToken = _feeToken();
        feeToken.setFailures(false, true);
        vm.startPrank(ALICE);
        zto.approve(address(adapter), 1 ether);
        feeToken.approve(address(adapter), 10 ether);
        vm.stopPrank();
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(feeToken)));
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 10 ether), ALICE);
        _assertFeeRollback(feeToken, 10 ether);
    }

    function test_endpointFailureRestoresBothTokenTransfersAndAllowances() public {
        MockZTO feeToken = _feeToken();
        vm.startPrank(ALICE);
        zto.approve(address(adapter), 1 ether);
        feeToken.approve(address(adapter), 10 ether);
        vm.stopPrank();
        home.setFailures(true, false);
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(EndpointMock.SendRejected.selector);
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 10 ether), ALICE);
        _assertFeeRollback(feeToken, 10 ether);
    }

    function _feeToken() private returns (MockZTO feeToken) {
        feeToken = new MockZTO();
        feeToken.mint(ALICE, 10 ether);
        home.setLzToken(address(feeToken));
    }

    function _assertFeeRollback(MockZTO feeToken, uint256 allowance) private view {
        _assertNoLock();
        assertEq(zto.allowance(ALICE, address(adapter)), 1 ether);
        assertEq(feeToken.allowance(ALICE, address(adapter)), allowance);
        assertEq(feeToken.balanceOf(ALICE), 10 ether);
        assertEq(feeToken.balanceOf(ENDPOINT), 0);
        assertEq(feeToken.balanceOf(address(adapter)), 0);
        assertEq(feeToken.balanceOf(address(0xFEE)), 0);
        assertEq(ALICE.balance, 10 ether);
        assertEq(ENDPOINT.balance, 0);
    }

    function testFuzz_everyTruncatedPayloadRevertsWithoutReleasing(uint256 lengthSeed, bytes32 contents) public {
        _bridgeOut(1 ether);
        bytes memory payload = new bytes(bound(lengthSeed, 0, 39));
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = contents[i % 32];
        }
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(); // Solidity calldata slicing rejects any packet shorter than 40 bytes.
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), payload, BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
        assertEq(zto.totalSupply(), SUPPLY);
    }

    function testFuzz_untrustedPeerCannotSpendEscrow(bytes32 peer) public {
        _bridgeOut(1 ether);
        if (peer == _b32(address(remoteOFT))) peer = peer ^ bytes32(uint256(1));
        Origin memory origin = Origin(REMOTE_EID, peer, 1);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, REMOTE_EID, peer));
        vm.prank(ENDPOINT);
        adapter.lzReceive(origin, bytes32(uint256(1)), abi.encodePacked(_b32(BOB), uint64(1_000_000)), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(BOB), 0);
    }

    function testFuzz_anyCallerExceptEndpointCannotRelease(address caller) public {
        _bridgeOut(1 ether);
        if (caller == ENDPOINT) caller = BOB;
        Origin memory origin = Origin(REMOTE_EID, _b32(address(remoteOFT)), 1);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, caller));
        vm.prank(caller);
        adapter.lzReceive(origin, bytes32(uint256(1)), abi.encodePacked(_b32(BOB), uint64(1_000_000)), BOB, "");
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
        assertEq(zto.balanceOf(BOB), 0);
    }

    function test_replacingPeerBlocksOldInflightMessageUntilRestored() public {
        _bridgeOut(2 ether);
        MessagingReceipt memory receipt = _sendBack(1 ether, "");
        EndpointMock.Packet memory p = remote.packet(receipt.guid);
        bytes32 pending = home.pending(receipt.guid);
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(BOB));
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, REMOTE_EID, _b32(address(remoteOFT))));
        home.deliver(p.origin, p.receiver, receipt.guid, p.message);
        assertEq(home.pending(receipt.guid), pending);
        assertFalse(home.delivered(receipt.guid));
        assertEq(zto.balanceOf(address(adapter)), 2 ether);
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(address(remoteOFT)));
        _deliver(remote, home, receipt.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 1 ether);
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_invalidOptionsBatchRollsBackEarlierValidEntry() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam(REMOTE_EID, 1, hex"00030100110100000000000000000000000000030d40");
        options[1] = EnforcedOptionParam(REMOTE_EID, 2, hex"0001");
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0001"));
        vm.prank(OWNER);
        adapter.setEnforcedOptions(options);
        assertEq(adapter.enforcedOptions(REMOTE_EID, 1), hex"");
        assertEq(adapter.enforcedOptions(REMOTE_EID, 2), hex"");
    }

    function test_sixLocalDecimalsRoundTrip() public {
        _roundTripWithLocalDecimals(6);
    }

    function test_nineLocalDecimalsRoundTrip() public {
        _roundTripWithLocalDecimals(9);
    }

    function _roundTripWithLocalDecimals(uint8 decimals) private {
        vm.mockCall(TOKEN, abi.encodeWithSignature("decimals()"), abi.encode(decimals));
        adapter = factory.deploy();
        uint256 rate = 10 ** (decimals - 6);
        assertEq(adapter.decimalConversionRate(), rate);
        vm.startPrank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(address(remoteOFT)));
        remoteOFT.setPeer(HOME_EID, _b32(address(adapter)));
        vm.stopPrank();
        uint256 localAmount = 123_456_789 * rate;
        SendParam memory p = _param(REMOTE_EID, BOB, localAmount + rate - 1, localAmount);
        vm.startPrank(ALICE);
        zto.approve(address(adapter), localAmount);
        (MessagingReceipt memory receipt,) = adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        vm.stopPrank();
        EndpointMock.Packet memory packet = home.packet(receipt.guid);
        assertEq(packet.message, abi.encodePacked(_b32(BOB), uint64(123_456_789)));
        _deliver(home, remote, receipt.guid);
        assertEq(remoteOFT.balanceOf(BOB), 123_456_789 * RATE);
        assertEq(zto.balanceOf(address(adapter)), localAmount);
        MessagingReceipt memory back = _sendBack(123_456_789 * RATE, "");
        _deliver(remote, home, back.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(remoteOFT.totalSupply(), 0);
    }
}
