// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeTestBase} from "./BridgeTestBase.sol";
import {ZTOAdapter} from "../src/ZTOAdapter.sol";
import {EndpointMock} from "./mocks/EndpointMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOFT, SendParam, MessagingFee, MessagingReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    EnforcedOptionParam,
    IOAppOptionsType3
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RejectingInspector {
    error Rejected();

    function inspect(bytes calldata, bytes calldata) external pure returns (bool) {
        revert Rejected();
    }
}

contract AdapterConfigurationTest is BridgeTestBase {
    function test_constructorSetsSpecifiedAddressesEvenWhenFactoryDeploys() public view {
        assertEq(adapter.token(), TOKEN);
        assertEq(address(adapter.endpoint()), ENDPOINT);
        assertEq(adapter.owner(), OWNER);
        assertEq(home.delegates(address(adapter)), OWNER);
        assertTrue(adapter.approvalRequired());
        assertEq(adapter.sharedDecimals(), 6);
        assertEq(adapter.decimalConversionRate(), RATE);
        assertEq(adapter.ETHEREUM_EID(), HOME_EID);
        assertEq(adapter.ROBINHOOD_EID(), REMOTE_EID);
        (bytes4 interfaceId, uint64 version) = adapter.oftVersion();
        assertEq(interfaceId, type(IOFT).interfaceId);
        assertEq(version, 1);
        (uint64 senderVersion, uint64 receiverVersion) = adapter.oAppVersion();
        assertEq(senderVersion, 1);
        assertEq(receiverVersion, 2);
    }

    function test_newDeploymentHasNoPeerOrOptionalHooks() public {
        ZTOAdapter fresh = factory.deploy();
        assertEq(fresh.peers(REMOTE_EID), bytes32(0));
        assertEq(fresh.msgInspector(), address(0));
        assertEq(fresh.preCrime(), address(0));
        assertEq(fresh.enforcedOptions(REMOTE_EID, 1).length, 0);
    }

    function test_factoryAndStrangerCannotSetPeer() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        vm.prank(address(factory));
        adapter.setPeer(REMOTE_EID, _b32(BOB));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        vm.prank(BOB);
        adapter.setPeer(REMOTE_EID, _b32(BOB));
        assertEq(adapter.peers(REMOTE_EID), _b32(address(remoteOFT)));
    }

    function test_ownerCanReplaceAndRemovePeerWithEvents() public {
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IOAppCore.PeerSet(REMOTE_EID, _b32(BOB));
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(BOB));
        assertTrue(adapter.allowInitializePath(Origin(REMOTE_EID, _b32(BOB), 1)));
        assertFalse(adapter.allowInitializePath(Origin(REMOTE_EID, _b32(address(remoteOFT)), 1)));
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        assertEq(adapter.peers(REMOTE_EID), bytes32(0));
    }

    function testFuzz_ownerCannotEnableAnotherChain(uint32 eid) public {
        vm.assume(eid != REMOTE_EID);
        vm.expectRevert(abi.encodeWithSelector(ZTOAdapter.UnsupportedEid.selector, eid));
        vm.prank(OWNER);
        adapter.setPeer(eid, _b32(BOB));
        assertEq(adapter.peers(eid), bytes32(0));
    }

    function test_allInheritedConfigurationIsOwnerOnly() public {
        bytes memory reason = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB);
        EnforcedOptionParam[] memory options = _enforced(1);
        vm.startPrank(BOB);
        vm.expectRevert(reason);
        adapter.setDelegate(BOB);
        vm.expectRevert(reason);
        adapter.setEnforcedOptions(options);
        vm.expectRevert(reason);
        adapter.setMsgInspector(BOB);
        vm.expectRevert(reason);
        adapter.setPreCrime(BOB);
        vm.expectRevert(reason);
        adapter.transferOwnership(BOB);
        vm.expectRevert(reason);
        adapter.renounceOwnership();
        vm.stopPrank();
    }

    function test_ownershipAndDelegateChangesHaveSeparateEffects() public {
        vm.startPrank(OWNER);
        adapter.setDelegate(ALICE);
        adapter.transferOwnership(BOB);
        vm.stopPrank();
        assertEq(adapter.owner(), BOB);
        assertEq(home.delegates(address(adapter)), ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vm.prank(OWNER);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        vm.prank(BOB);
        adapter.setPeer(REMOTE_EID, bytes32(0));
        assertEq(adapter.peers(REMOTE_EID), bytes32(0));
    }

    function test_enforcedOptionsAreCombinedAndAppliedToSend() public {
        EnforcedOptionParam[] memory enforced = _enforced(1);
        vm.prank(OWNER);
        adapter.setEnforcedOptions(enforced);
        (MessagingReceipt memory receipt,) = _sendHome(1 ether);
        bytes memory combined = abi.encodePacked(enforced[0].options, uint8(1), uint16(17), uint8(1), uint128(200_000));
        EndpointMock.Packet memory p = home.packet(receipt.guid);
        assertEq(p.options, combined);
    }

    function test_legacyOptionsCannotBypassEnforcedOptions() public {
        EnforcedOptionParam[] memory enforced = _enforced(1);
        vm.prank(OWNER);
        adapter.setEnforcedOptions(enforced);
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        p.extraOptions = hex"0001";
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, p.extraOptions));
        adapter.quoteSend(p, false);
    }

    function test_composedSendUsesSendAndCallOptionsAndIncludesOriginalSender() public {
        EnforcedOptionParam[] memory enforced = _enforced(2);
        vm.prank(OWNER);
        adapter.setEnforcedOptions(enforced);
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        p.extraOptions = "";
        p.composeMsg = hex"123456";
        vm.startPrank(ALICE);
        zto.approve(address(adapter), 1 ether);
        (MessagingReceipt memory receipt,) = adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        vm.stopPrank();
        EndpointMock.Packet memory packet = home.packet(receipt.guid);
        assertEq(packet.options, enforced[0].options);
        assertEq(packet.message, abi.encodePacked(_b32(BOB), uint64(1_000_000), _b32(ALICE), hex"123456"));
    }

    function test_inspectorRejectionRollsBackSend() public {
        RejectingInspector inspector = new RejectingInspector();
        vm.prank(OWNER);
        adapter.setMsgInspector(address(inspector));
        SendParam memory p = _param(REMOTE_EID, BOB, 1 ether, 1 ether);
        vm.expectRevert(RejectingInspector.Rejected.selector);
        adapter.quoteSend(p, false);
        vm.prank(ALICE);
        zto.approve(address(adapter), 1 ether);
        vm.expectRevert(RejectingInspector.Rejected.selector);
        vm.prank(ALICE);
        adapter.send{value: NATIVE_FEE}(p, MessagingFee(NATIVE_FEE, 0), ALICE);
        _assertNoLock();
    }

    function test_constructorRejectsTokenWithFewerThanSixDecimals() public {
        vm.mockCall(TOKEN, abi.encodeWithSignature("decimals()"), abi.encode(uint8(5)));
        vm.expectRevert(IOFT.InvalidLocalDecimals.selector);
        factory.deploy();
    }

    function test_runtimeFitsDeploymentPolicyAndContainsNoEscapeOpcodes() public view {
        bytes memory code = address(adapter).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }

    function _enforced(uint16 msgType) private pure returns (EnforcedOptionParam[] memory options) {
        options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam(
            REMOTE_EID, msgType, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(100_000))
        );
    }
}
