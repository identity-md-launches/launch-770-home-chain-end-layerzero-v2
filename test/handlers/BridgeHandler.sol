// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZTOAdapter} from "src/ZTOAdapter.sol";
import {MockZTO} from "../mocks/MockZTO.sol";
import {RemoteOFT} from "../mocks/RemoteOFT.sol";
import {EndpointMock} from "../mocks/EndpointMock.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Models claims independently of receipts and actual token balances. Only the handler is
/// targeted by Foundry: arbitrary minting, endpoint enqueueing and mock configuration are excluded.
contract BridgeHandler is Test {
    uint256 private constant RATE = 1e12;
    uint256 private constant FEE = 0.001 ether;
    uint32 private constant HOME = 30101;
    uint32 private constant REMOTE = 30416;
    address private constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    ZTOAdapter public immutable adapter;
    MockZTO public immutable zto;
    RemoteOFT public immutable oft;
    EndpointMock public immutable home;
    EndpointMock public immutable remote;
    address[3] public actors;
    uint256[3] public expectedHome;
    uint256[3] public expectedRemote;
    uint256 public locked;
    uint256 public released;
    uint256 public donated;
    uint256 public outboundValue;
    uint256 public inboundValue;
    uint256 public sends;
    uint256 public burns;
    uint256 public credits;
    uint256 public rejectedCalls;
    bytes32 public lastInbound;

    struct Claim {
        bytes32 guid;
        uint256 recipient;
        uint256 amount;
    }
    Claim[] private outbound;
    Claim[] private inbound;

    constructor(ZTOAdapter a, MockZTO t, RemoteOFT o, EndpointMock h, EndpointMock r, address[3] memory users) {
        adapter = a;
        zto = t;
        oft = o;
        home = h;
        remote = r;
        actors = users;
        for (uint256 i; i < 3; ++i) {
            expectedHome[i] = t.balanceOf(users[i]);
        }
    }

    function sendOut(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 requested = _amount(amountSeed, zto.balanceOf(actors[from]));
        uint256 amount = requested - requested % RATE;
        SendParam memory p = _param(REMOTE, actors[to], requested, amount);
        vm.startPrank(actors[from]);
        zto.approve(address(adapter), requested);
        (MessagingReceipt memory receipt, OFTReceipt memory amounts) =
            adapter.send{value: FEE}(p, MessagingFee(FEE, 0), actors[from]);
        vm.stopPrank();
        assertEq(amounts.amountSentLD, amount, "wrong lock receipt");
        assertEq(amounts.amountReceivedLD, amount, "application fee");
        assertEq(zto.allowance(actors[from], address(adapter)), requested - amount, "dust allowance");
        EndpointMock.Packet memory packet = home.packet(receipt.guid);
        assertEq(packet.message, abi.encodePacked(_b32(actors[to]), uint64(amount / RATE)), "wrong claim");
        expectedHome[from] -= amount;
        locked += amount;
        outboundValue += amount;
        outbound.push(Claim(receipt.guid, to, amount));
        ++sends;
    }

    function deliverOut(uint256 seed) public {
        if (outbound.length == 0) return;
        uint256 i = seed % outbound.length;
        Claim memory claim = outbound[i];
        _deliver(home, remote, claim.guid);
        expectedRemote[claim.recipient] += claim.amount;
        outboundValue -= claim.amount;
        outbound[i] = outbound[outbound.length - 1];
        outbound.pop();
    }

    function sendBack(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool compose) public {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 requested = _amount(amountSeed, oft.balanceOf(actors[from]));
        uint256 amount = requested - requested % RATE;
        SendParam memory p = _param(HOME, actors[to], requested, amount);
        if (compose) p.composeMsg = hex"cafe";
        vm.prank(actors[from]);
        (MessagingReceipt memory receipt, OFTReceipt memory amounts) =
            oft.send{value: FEE}(p, MessagingFee(FEE, 0), actors[from]);
        assertEq(amounts.amountSentLD, amount, "wrong burn receipt");
        assertEq(amounts.amountReceivedLD, amount, "wrong return claim");
        expectedRemote[from] -= amount;
        inboundValue += amount;
        inbound.push(Claim(receipt.guid, to, amount));
        ++burns;
    }

    function deliverBack(uint256 seed) public {
        if (inbound.length == 0) return;
        uint256 i = seed % inbound.length;
        Claim memory claim = inbound[i];
        _deliver(remote, home, claim.guid);
        expectedHome[claim.recipient] += claim.amount;
        released += claim.amount;
        inboundValue -= claim.amount;
        inbound[i] = inbound[inbound.length - 1];
        inbound.pop();
        lastInbound = claim.guid;
        ++credits;
    }

    function transferBetweenUsers(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool onRemote) public {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 balance = onRemote ? oft.balanceOf(actors[from]) : zto.balanceOf(actors[from]);
        uint256 amount = _amount(amountSeed, balance);
        vm.prank(actors[from]);
        if (onRemote) {
            assertTrue(oft.transfer(actors[to], amount));
            expectedRemote[from] -= amount;
            expectedRemote[to] += amount;
        } else {
            assertTrue(zto.transfer(actors[to], amount));
            expectedHome[from] -= amount;
            expectedHome[to] += amount;
        }
    }

    function donate(uint256 whoSeed, uint256 amountSeed) public {
        uint256 who = whoSeed % 3;
        uint256 amount = _amount(amountSeed, zto.balanceOf(actors[who]));
        vm.prank(actors[who]);
        assertTrue(zto.transfer(address(adapter), amount));
        expectedHome[who] -= amount;
        donated += amount;
    }

    /// @dev Fail *after* token debit, then require balances, allowances, native fees and nonces
    /// to be unchanged. Unexpected reverts fail the invariant campaign.
    function rejectedSend(uint256 whoSeed, uint256 amountSeed) public {
        address who = actors[whoSeed % 3];
        uint256 amount = _amount(amountSeed, zto.balanceOf(who));
        vm.prank(who);
        zto.approve(address(adapter), amount);
        bytes32 beforeState = stateDigest();
        home.setFailures(true, false);
        SendParam memory p = _param(REMOTE, who, amount, 0);
        vm.expectRevert(EndpointMock.SendRejected.selector);
        vm.prank(who);
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), who);
        home.setFailures(false, false);
        assertEq(stateDigest(), beforeState, "failed send changed state");
        ++rejectedCalls;
    }

    /// @dev Leave failed packets pending; a later random delivery or drain must still redeem them.
    function rejectedReceive(uint256 seed, bool removePeer) public {
        if (inbound.length == 0) return;
        Claim memory claim = inbound[seed % inbound.length];
        EndpointMock.Packet memory p = remote.packet(claim.guid);
        bytes32 pendingBefore = home.pending(claim.guid);
        bytes32 beforeState = stateDigest();
        if (removePeer) {
            vm.prank(OWNER);
            adapter.setPeer(REMOTE, bytes32(0));
            vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, REMOTE));
        } else {
            zto.setFailures(true, false);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(zto)));
        }
        home.deliver(p.origin, p.receiver, claim.guid, p.message);
        if (removePeer) {
            vm.prank(OWNER);
            adapter.setPeer(REMOTE, _b32(address(oft)));
        } else {
            zto.setFailures(false, false);
        }
        assertEq(stateDigest(), beforeState, "failed receive changed state");
        assertEq(home.pending(claim.guid), pendingBefore, "claim consumed on failure");
        assertFalse(home.delivered(claim.guid));
        ++rejectedCalls;
    }

    function unauthorizedCalls(uint256 whoSeed, uint256 amountSeed) public {
        address who = actors[whoSeed % 3];
        bytes32 beforeState = stateDigest();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        vm.prank(who);
        adapter.setPeer(REMOTE, _b32(who));
        Origin memory origin = Origin(REMOTE, _b32(address(oft)), 1);
        bytes memory payload = abi.encodePacked(_b32(who), uint64(bound(amountSeed, 0, type(uint64).max)));
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, who));
        vm.prank(who);
        adapter.lzReceive(origin, bytes32(uint256(1)), payload, who, "");
        assertEq(adapter.peers(REMOTE), _b32(address(oft)));
        assertEq(stateDigest(), beforeState, "unauthorized call changed state");
        ++rejectedCalls;
    }

    function replayLastReceive() public {
        if (lastInbound == bytes32(0)) return;
        EndpointMock.Packet memory p = remote.packet(lastInbound);
        bytes32 beforeState = stateDigest();
        vm.expectRevert(EndpointMock.InvalidPacket.selector);
        home.deliver(p.origin, p.receiver, lastInbound, p.message);
        assertEq(stateDigest(), beforeState, "replay released custody");
        ++rejectedCalls;
    }

    /// @dev Called only by afterInvariant, never targeted. Drain in reverse order and consolidate
    /// remote dust so that the entire remaining remote supply is redeemable at six shared decimals.
    function drain() external {
        while (outbound.length > 0) deliverOut(outbound.length - 1);
        while (inbound.length > 0) deliverBack(inbound.length - 1);
        transferBetweenUsers(1, 0, type(uint256).max, true);
        transferBetweenUsers(2, 0, type(uint256).max, true);
        uint256 remaining = oft.balanceOf(actors[0]);
        assertEq(remaining % RATE, 0, "aggregate remote dust");
        sendBack(0, 0, type(uint256).max, false);
        deliverBack(0);
        assertEq(oft.totalSupply(), 0, "claims could not be burned");
        assertEq(zto.balanceOf(address(adapter)), donated, "claims could not be redeemed");
    }

    function stateDigest() public view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                zto.totalSupply(),
                oft.totalSupply(),
                zto.balanceOf(address(adapter)),
                address(adapter).balance,
                address(home).balance,
                address(remote).balance,
                home.lastGuid(),
                remote.lastGuid(),
                home.lastComposeGuid()
            )
        );
        for (uint256 i; i < 3; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    zto.balanceOf(actors[i]),
                    oft.balanceOf(actors[i]),
                    zto.allowance(actors[i], address(adapter)),
                    actors[i].balance
                )
            );
        }
        bytes32 path = keccak256(abi.encode(address(adapter), REMOTE, _b32(address(oft))));
        return keccak256(abi.encode(digest, home.outboundNonce(path)));
    }

    function _amount(uint256 seed, uint256 balance) private pure returns (uint256) {
        if (seed == type(uint256).max || seed % 8 == 4) return balance;
        if (seed % 8 == 0) return 0;
        if (seed % 8 == 1) return balance == 0 ? 0 : 1;
        if (seed % 8 == 2) return balance < RATE - 1 ? balance : RATE - 1;
        if (seed % 8 == 3) return balance < RATE ? balance : RATE;
        return bound(seed, 0, balance);
    }

    function _param(uint32 dst, address to, uint256 amount, uint256 minimum) private pure returns (SendParam memory) {
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
        return SendParam(dst, _b32(to), amount, minimum, options, "", "");
    }

    function _b32(address who) private pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    function _deliver(EndpointMock source, EndpointMock destination, bytes32 guid) private {
        EndpointMock.Packet memory p = source.packet(guid);
        destination.deliver(p.origin, p.receiver, guid, p.message);
    }
}
