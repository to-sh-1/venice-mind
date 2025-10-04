// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockVVV
 * @dev Mock VVV token for testing purposes
 * @notice This is a simple ERC20 token used for testing the Venice Mind Burn system
 */
contract MockVVV is ERC20 {
    /// @notice The owner of the contract who can mint tokens
    address public owner;

    /// @notice Event emitted when tokens are minted
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Error thrown when non-owner tries to mint
    error OnlyOwner();

    /**
     * @dev Constructor sets the token name, symbol, and owner
     * @param _owner The owner address who can mint tokens
     */
    constructor(address _owner) ERC20("Venice Vision Vault", "VVV") {
        owner = _owner;
    }

    /**
     * @notice Mints tokens to a specified address
     * @dev Only the owner can call this function
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) {
            revert OnlyOwner();
        }
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Burns tokens from the caller's balance
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burns tokens from a specified address
     * @dev Requires allowance from the token holder
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    /**
     * @notice Allows burning tokens by transferring to address(1)
     * @dev This is a workaround for the burn mechanism
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (to == address(1)) {
            // If transferring to address(1), burn the tokens
            _burn(from, value);
        } else {
            super._update(from, to, value);
        }
    }
}
