// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only lossless token with independently injectable transfer failures.
contract MockZTO is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;

    constructor() ERC20("Zero To One", "ZTO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailures(bool transferFailure, bool transferFromFailure) external {
        failTransfer = transferFailure;
        failTransferFrom = transferFromFailure;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, value);
    }
}
