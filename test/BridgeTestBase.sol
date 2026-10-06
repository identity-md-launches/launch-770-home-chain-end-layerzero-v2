// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZTOAdapter} from "../src/ZTOAdapter.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {RemoteOFT} from "./mocks/RemoteOFT.sol";
import {EndpointMock} from "./mocks/EndpointMock.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

contract DeploymentFactory {
    function deploy() external returns (ZTOAdapter) {
        return new ZTOAdapter();
    }
}

abstract contract BridgeTestBase is Test {
    address internal constant TOKEN = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint32 internal constant HOME_EID = 30101;
    uint32 internal constant REMOTE_EID = 30416;
    uint256 internal constant RATE = 1e12;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant NATIVE_FEE = 0.001 ether;

    ZTOAdapter internal adapter;
    MockZTO internal zto;
    EndpointMock internal home;
    EndpointMock internal remote;
    RemoteOFT internal remoteOFT;
    DeploymentFactory internal factory;

    function setUp() public virtual {
        vm.chainId(1);
        MockZTO tokenImplementation = new MockZTO();
        vm.etch(TOKEN, address(tokenImplementation).code);
        zto = MockZTO(TOKEN);
        EndpointMock endpointImplementation = new EndpointMock(HOME_EID);
        vm.etch(ENDPOINT, address(endpointImplementation).code);
        home = EndpointMock(ENDPOINT);
        remote = new EndpointMock(REMOTE_EID);
        home.setRemote(REMOTE_EID, remote);
        remote.setRemote(HOME_EID, home);
        factory = new DeploymentFactory();
        adapter = factory.deploy();
        remoteOFT = new RemoteOFT(address(remote), OWNER);
        vm.startPrank(OWNER);
        adapter.setPeer(REMOTE_EID, _b32(address(remoteOFT)));
        remoteOFT.setPeer(HOME_EID, _b32(address(adapter)));
        vm.stopPrank();
        zto.mint(ALICE, SUPPLY);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    function _b32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _param(uint32 dst, address to, uint256 amount, uint256 minimum) internal pure returns (SendParam memory) {
        // Type 3 executor lzReceive option: worker 1, length 17, option 1, 200,000 gas.
        bytes memory options = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
        return SendParam(dst, _b32(to), amount, minimum, options, "", "");
    }

    function _sendHome(uint256 amount) internal returns (MessagingReceipt memory receipt, OFTReceipt memory oft) {
        SendParam memory param = _param(REMOTE_EID, BOB, amount, (amount / RATE) * RATE);
        vm.startPrank(ALICE);
        zto.approve(address(adapter), amount);
        (receipt, oft) = adapter.send{value: NATIVE_FEE}(param, MessagingFee(NATIVE_FEE, 0), ALICE);
        vm.stopPrank();
    }

    function _sendBack(uint256 amount, bytes memory compose) internal returns (MessagingReceipt memory receipt) {
        SendParam memory param = _param(HOME_EID, ALICE, amount, amount);
        param.composeMsg = compose;
        vm.prank(BOB);
        (receipt,) = remoteOFT.send{value: NATIVE_FEE}(param, MessagingFee(NATIVE_FEE, 0), BOB);
    }

    function _deliver(EndpointMock source, EndpointMock destination, bytes32 guid) internal {
        EndpointMock.Packet memory p = source.packet(guid);
        destination.deliver(p.origin, p.receiver, guid, p.message);
    }

    function _bridgeOut(uint256 amount) internal {
        (MessagingReceipt memory receipt,) = _sendHome(amount);
        _deliver(home, remote, receipt.guid);
    }

    function _assertNoLock() internal view {
        assertEq(zto.balanceOf(ALICE), SUPPLY);
        assertEq(zto.balanceOf(address(adapter)), 0);
        assertEq(zto.totalSupply(), SUPPLY);
        assertEq(home.lastGuid(), bytes32(0));
    }
}
