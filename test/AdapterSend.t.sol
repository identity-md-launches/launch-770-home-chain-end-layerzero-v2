// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {EndpointMock} from "./mocks/EndpointMock.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {
    IOFT,
    SendParam,
    OFTLimit,
    OFTFeeDetail,
    OFTReceipt,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppSender} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AdapterSendTest is BridgeTestBase {
    function test_quoteHasNoBridgeFeeAndDoesNotMoveTokens() public view {
        SendParam memory p = _param(REMOTE_EID, BOB, 7 ether + 123, 7 ether);
        (OFTLimit memory limit, OFTFeeDetail[] memory fees, OFTReceipt memory oft) = adapter.quoteOFT(p);
        assertEq(limit.minAmountLD, 0);
        assertEq(limit.maxAmountLD, SUPPLY);
        assertEq(fees.length, 0);
        assertEq(oft.amountSentLD, 7 ether);
        assertEq(oft.amountReceivedLD, 7 ether);
        MessagingFee memory quote = adapter.quoteSend(p, false);
        assertEq(quote.nativeFee, NATIVE_FEE);
        assertEq(quote.lzTokenFee, 0);
        _assertNoLock();
    }

    function test_sendLocksTokensEncodesPacketAndRetainsDust() public {
        (MessagingReceipt memory receipt, OFTReceipt memory oft) = _sendHome(7 ether + 123);
        assertEq(receipt.nonce, 1);
        assertEq(receipt.guid, home.lastGuid());
        assertEq(receipt.fee.nativeFee, NATIVE_FEE);
        assertEq(oft.amountSentLD, 7 ether);
        assertEq(oft.amountReceivedLD, 7 ether);
        assertEq(zto.balanceOf(address(adapter)), 7 ether);
        assertEq(zto.balanceOf(ALICE), SUPPLY - 7 ether);
        assertEq(zto.allowance(ALICE, address(adapter)), 123);
        assertEq(zto.totalSupply(), SUPPLY);
        assertEq(remoteOFT.totalSupply(), 0); // Delivery is asynchronous.
        assertEq(address(adapter).balance, 0);
        EndpointMock.Packet memory p = home.packet(receipt.guid);
        assertEq(p.dstEid, REMOTE_EID);
        assertEq(p.receiver, address(remoteOFT));
        assertEq(p.origin.srcEid, HOME_EID);
        assertEq(p.origin.sender, _b32(address(adapter)));
        // Independent packing assertion: 32-byte recipient followed by 8-byte amount in SD.
        assertEq(p.message, abi.encodePacked(_b32(BOB), uint64(7_000_000)));
        assertEq(p.options, _param(REMOTE_EID, BOB, 0, 0).extraOptions);
        _deliver(home, remote, receipt.guid);
        assertEq(remoteOFT.balanceOf(BOB), 7 ether);
        assertEq(remoteOFT.totalSupply(), zto.balanceOf(address(adapter)));
    }

    function testFuzz_roundTripConservesSupplyAndDust(uint96 requested) public {
        uint256 amount = bound(uint256(requested), RATE, SUPPLY);
        uint256 rounded = (amount / RATE) * RATE;
        _bridgeOut(amount);
        assertEq(zto.balanceOf(ALICE), SUPPLY - rounded);
        assertEq(zto.balanceOf(address(adapter)), rounded);
        assertEq(remoteOFT.totalSupply(), rounded);
        assertEq(zto.totalSupply(), SUPPLY);
        MessagingReceipt memory back = _sendBack(rounded, "");
        assertEq(remoteOFT.totalSupply(), 0);
        assertEq(zto.balanceOf(address(adapter)), rounded); // Awaiting inbound execution.
        _deliver(remote, home, back.guid);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(zto.totalSupply(), SUPPLY);
        assertEq(remoteOFT.balanceOf(BOB), 0);
    }

    function test_sendWithoutApprovalReverts() public {
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, 1 ether)
        );
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        _assertNoLock();
    }

    function test_senderCannotSpendAnotherUsersApproval() public {
        vm.prank(ALICE);
        zto.approve(address(adapter), 1 ether);
        vm.prank(BOB);
        zto.approve(address(adapter), 1 ether);
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 1 ether));
        vm.prank(BOB);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), BOB);
        _assertNoLock();
        assertEq(zto.allowance(ALICE, address(adapter)), 1 ether);
    }

    function test_slippageAfterDustRemovalRevertsQuoteAndSend() public {
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether + 1, 1 ether + 1);
        bytes memory reason = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 1 ether, 1 ether + 1);
        vm.expectRevert(reason);
        adapter.quoteSend(p, false);
        vm.expectRevert(reason);
        adapter.quoteOFT(p);
        vm.prank(ALICE);
        zto.approve(address(adapter), p.amountLD);
        vm.expectRevert(reason);
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        _assertNoLock();
    }

    function test_zeroAndDustOnlyAmountsFollowStandardOFTSemantics() public {
        (MessagingReceipt memory first, OFTReceipt memory zero) = _sendHome(0);
        assertEq(zero.amountReceivedLD, 0);
        _deliver(home, remote, first.guid);
        (MessagingReceipt memory second, OFTReceipt memory dust) = _sendHome(RATE - 1);
        assertEq(dust.amountSentLD, 0);
        _deliver(home, remote, second.guid);
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(remoteOFT.totalSupply(), 0);
    }

    function test_uint64MaximumSharedAmountCanBridge() public {
        uint256 amount = uint256(type(uint64).max) * RATE;
        zto.mint(ALICE, amount - SUPPLY);
        _bridgeOut(amount);
        assertEq(remoteOFT.balanceOf(BOB), amount);
        assertEq(zto.balanceOf(address(adapter)), amount);
    }

    function test_sharedAmountOverflowRevertsAndRollsBackLock() public {
        uint256 amountSD = uint256(type(uint64).max) + 1;
        uint256 amount = amountSD * RATE;
        zto.mint(ALICE, amount - SUPPLY);
        SendParam memory p = _param(REMOTE_EID, BOB, amount, amount);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        adapter.quoteSend(p, false);
        vm.prank(ALICE);
        zto.approve(address(adapter), amount);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        assertEq(zto.balanceOf(ALICE), amount);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(zto.allowance(ALICE, address(adapter)), amount);
        assertEq(home.lastGuid(), bytes32(0));
    }

    function test_noPeerRevertsAndRollsBackLock() public {
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, REMOTE_EID));
        adapter.quoteSend(p, false);
        _expectFailedSend(
            p, MessagingFee(NATIVE_FEE, 0), NATIVE_FEE, abi.encodeWithSelector(IOAppCore.NoPeer.selector, REMOTE_EID)
        );
    }

    function test_unconfiguredDestinationCannotSend() public {
        SendParam memory p = _param(30110, BOB, 1 ether, 1 ether);
        _expectFailedSend(
            p, MessagingFee(NATIVE_FEE, 0), NATIVE_FEE, abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(30110))
        );
    }

    function test_nativeValueMustEqualSuppliedFee() public {
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        _expectFailedSend(
            p,
            MessagingFee(NATIVE_FEE, 0),
            NATIVE_FEE - 1,
            abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, NATIVE_FEE - 1)
        );
        _expectFailedSend(
            p,
            MessagingFee(NATIVE_FEE, 0),
            NATIVE_FEE + 1,
            abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, NATIVE_FEE + 1)
        );
    }

    function test_staleUnderpricedFeeRevertsAndRollsBackLock() public {
        _expectFailedSend(
            _param(REMOTE_EID, BOB, 1 ether, 1 ether),
            MessagingFee(NATIVE_FEE - 1, 0),
            NATIVE_FEE - 1,
            abi.encodeWithSelector(EndpointMock.InsufficientFee.selector)
        );
    }

    function test_endpointFailureRollsBackTokensAllowanceAndNativePayment() public {
        home.setFailures(true, false);
        _expectFailedSend(
            _param(REMOTE_EID, BOB, 1 ether, 1 ether),
            MessagingFee(NATIVE_FEE, 0),
            NATIVE_FEE,
            abi.encodeWithSelector(EndpointMock.SendRejected.selector)
        );
    }

    function test_falseTransferFromReturnRevertsWithoutSending() public {
        zto.setFailures(false, true);
        _expectFailedSend(
            _param(REMOTE_EID, BOB, 1 ether, 1 ether),
            MessagingFee(NATIVE_FEE, 0),
            NATIVE_FEE,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN)
        );
    }

    function test_excessNativeFeeIsRefundedToSpecifiedAddress() public {
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        uint256 bobBefore = BOB.balance;
        uint256 aliceBefore = ALICE.balance;
        vm.startPrank(ALICE);
        zto.approve(address(adapter), 1 ether);
        (MessagingReceipt memory receipt,) =
            adapter.send{value: 2 * NATIVE_FEE}(p, MessagingFee(2 * NATIVE_FEE, 0), BOB);
        vm.stopPrank();
        assertEq(receipt.fee.nativeFee, NATIVE_FEE);
        assertEq(BOB.balance, bobBefore + NATIVE_FEE);
        assertEq(ALICE.balance, aliceBefore - 2 * NATIVE_FEE);
        assertEq(address(adapter).balance, 0);
    }

    function test_optionalLayerZeroTokenFeeGoesToEndpoint() public {
        MockZTO feeToken = new MockZTO();
        home.setLzToken(address(feeToken));
        feeToken.mint(ALICE, 10 ether);
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        MessagingFee memory fee = adapter.quoteSend(p, true);
        assertEq(fee.lzTokenFee, 10 ether);
        vm.startPrank(ALICE);
        zto.approve(address(adapter), 1 ether);
        feeToken.approve(address(adapter), fee.lzTokenFee);
        adapter.send{value: fee.nativeFee}(p, fee, ALICE);
        vm.stopPrank();
        assertEq(feeToken.balanceOf(ALICE), 0);
        assertEq(feeToken.balanceOf(address(adapter)), 0);
        assertEq(feeToken.balanceOf(address(0xFEE)), 10 ether);
        assertEq(zto.balanceOf(address(adapter)), 1 ether);
    }

    function test_unavailableLayerZeroFeeTokenRevertsAtomically() public {
        _expectFailedSend(
            _param(REMOTE_EID, BOB, 1 ether, 1 ether),
            MessagingFee(NATIVE_FEE, 10 ether),
            NATIVE_FEE,
            abi.encodeWithSelector(OAppSender.LzTokenUnavailable.selector)
        );
    }

    function _expectFailedSend(SendParam memory p, MessagingFee memory fee, uint256 value, bytes memory reason)
        internal
    {
        vm.prank(ALICE);
        zto.approve(address(adapter), p.amountLD);
        uint256 nativeBefore = ALICE.balance;
        vm.expectRevert(reason);
        vm.prank(ALICE);
        adapter.send{value: value}(p, fee, ALICE);
        _assertNoLock();
        assertEq(zto.allowance(ALICE, address(adapter)), p.amountLD);
        assertEq(ALICE.balance, nativeBefore);
    }
}
