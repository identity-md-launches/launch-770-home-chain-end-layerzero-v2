// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Ethereum custody adapter for the existing Zero To One token.
/// @dev Uses the standard lossless ERC20 OFTAdapter with six shared decimals.
///      The sole remote path is Robinhood. Peer configuration remains an owner responsibility.
contract ZTOAdapter is OFTAdapter {
    address public constant ZTO = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;
    address public constant ETHEREUM_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant INITIAL_OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    uint32 public constant ETHEREUM_EID = 30101;
    uint32 public constant ROBINHOOD_EID = 30416;

    error UnsupportedEid(uint32 eid);

    /// @dev No arguments or deployment value. The factory/caller receives no privileges.
    constructor() OFTAdapter(ZTO, ETHEREUM_ENDPOINT, INITIAL_OWNER) Ownable(INITIAL_OWNER) {}

    /// @notice Sets or removes the single Robinhood OFT peer, using the standard bytes32 encoding.
    /// @dev A zero peer removes the route; changing a peer affects pending messages as well.
    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        if (eid != ROBINHOOD_EID) revert UnsupportedEid(eid);
        _setPeer(eid, peer);
    }
}
