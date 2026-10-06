// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Test-only standard OFT. Starts with zero supply and has no arbitrary mint entry point.
contract RemoteOFT is OFT {
    constructor(address endpoint, address owner) OFT("Remote ZTO", "ZTO", endpoint, owner) Ownable(owner) {}
}
