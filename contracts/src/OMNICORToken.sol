// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title OMNICORToken
/// @notice Fixed-supply ERC-20. The entire supply is minted once at deploy to
///         the given distributor; no further minting is possible.
contract OMNICORToken is ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_, address distributor)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(distributor, TOTAL_SUPPLY);
    }
}
