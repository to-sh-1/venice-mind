// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev Minimal clone of OpenZeppelin's ReentrancyGuardUpgradeable to avoid adding the entire module.
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @notice Initializes reentrancy guard storage during proxy initialization
     */
    function reentrancyGuardInit() internal onlyInitializing {
        reentrancyGuardInitUnchained();
    }

    /**
     * @notice Initializes the guard state without re-invoking parent initializers
     */
    function reentrancyGuardInitUnchained() internal onlyInitializing {
        _status = NOT_ENTERED;
    }

    /**
     * @notice Prevents a function from being re-entered
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        require(_status != ENTERED, "ReentrancyGuard: reentrant call");
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = NOT_ENTERED;
    }
}
