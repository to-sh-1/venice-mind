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
     * @dev Only callable by the contract owner
     * @param to The address receiving the newly minted tokens
     * @param amount The number of tokens to mint
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
     * @param amount The quantity of tokens to destroy
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burns tokens from a specified address using allowance
     * @param from The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    /**
     * @inheritdoc ERC20
     * @dev Allows transfers to the zero address for burn semantics
     */
    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        address owner_ = _msgSender();
        _transferAllowingZero(owner_, to, value);
        return true;
    }

    /**
     * @inheritdoc ERC20
     * @dev Allows transfers to the zero address for burn semantics
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferAllowingZero(from, to, value);
        return true;
    }

    /**
     * @notice Internal helper that skips the zero-address recipient check
     * @param from The token sender
     * @param to The token recipient (may be zero address)
     * @param value The amount being transferred
     */
    function _transferAllowingZero(
        address from,
        address to,
        uint256 value
    ) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(from, to, value);
    }
}
