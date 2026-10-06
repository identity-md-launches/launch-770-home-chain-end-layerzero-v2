// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Local transport model, not a DVN/ULN implementation. Delivery consumes a queued packet
///      before the receiver call; a receiver revert restores it so it can be retried.
contract EndpointMock {
    uint32 public immutable eid;
    uint256 public constant NATIVE_FEE = 0.001 ether;
    uint256 public constant LZ_TOKEN_FEE = 10 ether;
    address public lzToken;
    bool public rejectSend;
    bool public rejectCompose;
    mapping(address => address) public delegates;
    mapping(uint32 => EndpointMock) public remotes;
    mapping(bytes32 => uint64) public outboundNonce;
    mapping(bytes32 => bool) public delivered;
    mapping(bytes32 => bytes32) public pending;

    struct Packet {
        Origin origin;
        uint32 dstEid;
        address receiver;
        bytes message;
        bytes options;
    }

    mapping(bytes32 => Packet) private packets;
    bytes32 public lastGuid;
    address public lastComposeFrom;
    address public lastComposeTo;
    bytes32 public lastComposeGuid;
    uint16 public lastComposeIndex;
    bytes public lastComposeMessage;

    error SendRejected();
    error ComposeRejected();
    error InsufficientFee();
    error UnknownRemote();
    error InvalidPacket();
    error RefundFailed();

    constructor(uint32 localEid) {
        eid = localEid;
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function setRemote(uint32 remoteEid, EndpointMock remote) external {
        remotes[remoteEid] = remote;
    }

    function setFailures(bool sendFailure, bool composeFailure) external {
        rejectSend = sendFailure;
        rejectCompose = composeFailure;
    }

    function setLzToken(address token) external {
        lzToken = token;
    }

    function quote(MessagingParams calldata params, address) external pure returns (MessagingFee memory) {
        return MessagingFee(NATIVE_FEE, params.payInLzToken ? LZ_TOKEN_FEE : 0);
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        if (rejectSend) revert SendRejected();
        if (msg.value < NATIVE_FEE) revert InsufficientFee();
        if (params.payInLzToken) {
            if (lzToken == address(0) || IERC20(lzToken).balanceOf(address(this)) < LZ_TOKEN_FEE) {
                revert InsufficientFee();
            }
            require(IERC20(lzToken).transfer(address(0xFEE), LZ_TOKEN_FEE));
        }
        EndpointMock destination = remotes[params.dstEid];
        if (address(destination) == address(0)) revert UnknownRemote();
        bytes32 path = keccak256(abi.encode(msg.sender, params.dstEid, params.receiver));
        uint64 nonce = ++outboundNonce[path];
        Origin memory origin = Origin(eid, bytes32(uint256(uint160(msg.sender))), nonce);
        bytes32 guid = keccak256(abi.encode(nonce, eid, msg.sender, params.dstEid, params.receiver));
        address receiver = address(uint160(uint256(params.receiver)));
        packets[guid] = Packet(origin, params.dstEid, receiver, params.message, params.options);
        lastGuid = guid;
        destination.enqueue(origin, receiver, guid, params.message);
        receipt = MessagingReceipt(guid, nonce, MessagingFee(NATIVE_FEE, params.payInLzToken ? LZ_TOKEN_FEE : 0));
        uint256 refund = msg.value - NATIVE_FEE;
        if (refund > 0) {
            (bool success,) = refundAddress.call{value: refund}("");
            if (!success) revert RefundFailed();
        }
    }

    function packet(bytes32 guid) external view returns (Packet memory) {
        return packets[guid];
    }

    function enqueue(Origin calldata origin, address receiver, bytes32 guid, bytes calldata message) external {
        if (msg.sender != address(remotes[origin.srcEid])) revert UnknownRemote();
        if (pending[guid] != bytes32(0) || delivered[guid]) revert InvalidPacket();
        pending[guid] = keccak256(abi.encode(origin, receiver, message));
    }

    function deliver(Origin calldata origin, address receiver, bytes32 guid, bytes calldata message) external {
        if (delivered[guid] || pending[guid] != keccak256(abi.encode(origin, receiver, message))) {
            revert InvalidPacket();
        }
        delete pending[guid];
        delivered[guid] = true;
        ILayerZeroReceiver(receiver).lzReceive(origin, guid, message, msg.sender, "");
    }

    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        if (rejectCompose) revert ComposeRejected();
        lastComposeFrom = msg.sender;
        lastComposeTo = to;
        lastComposeGuid = guid;
        lastComposeIndex = index;
        lastComposeMessage = message;
    }
}
