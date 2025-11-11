// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "./utils/ReentrancyGuardUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title VeniceMind
 * @dev Mind subcontract that tracks VVV deposits and allows the owner to burn accounted balances
 */
contract VeniceMind is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The VVV token contract address
    IERC20 public vvvToken;

    /// @notice Total amount of VVV burned from this mind
    uint256 public totalBurned;

    /// @notice Burn address constant
    address private constant BURN_ADDRESS = address(0);

    /// @notice Mapping of contributor address to total amount contributed
    mapping(address => uint256) public contributedBy;

    /// @notice Array of all contributors who have interacted with this mind
    address[] private contributors;

    /// @notice Mapping to track if an address is already in contributors array
    mapping(address => bool) private isContributor;

    // Legacy storage preserved for upgrade compatibility (no longer used)
    mapping(address => uint256) private _legacyPendingBy;
    uint256 private _legacyTotalPending;

    /// @notice Event emitted when VVV tokens are deposited
    event Deposit(
        address indexed contributor,
        uint256 amount,
        uint256 totalContributed
    );

    /// @notice Event emitted when VVV tokens are burned
    event Burn(
        address indexed contributor,
        uint256 amount,
        uint256 totalBurned
    );

    /// @notice Event emitted when ownership is transferred
    event OwnerTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Event emitted when tokens are withdrawn via emergencyWithdraw
    event EmergencyWithdrawal(
        address indexed token,
        uint256 amount,
        address indexed to
    );

    /// @notice Error thrown when trying to burn zero tokens
    error NoTokensToBurn();

    /// @notice Error thrown when attempting to deposit zero tokens
    error ZeroAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the clone with token and ownership configuration
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner of the mind
     */
    function initialize(
        address _vvvToken,
        address _owner
    ) external initializer {
        require(_vvvToken != address(0), "VVV token address cannot be zero");
        require(_owner != address(0), "Owner address cannot be zero");

        __Ownable_init(_owner);
        reentrancyGuardInit();
        vvvToken = IERC20(_vvvToken);
    }

    /**
     * @notice Deposits VVV tokens for the caller and updates contribution totals
     * @param amount The amount of VVV tokens to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Burns the entire VVV balance held by this mind
     * @dev Sends the full balance to the canonical burn address and updates running totals
     */
    function burn() external onlyOwner nonReentrant {
        IERC20 token = vvvToken;
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) {
            revert NoTokensToBurn();
        }

        token.safeTransfer(BURN_ADDRESS, balance);
        totalBurned += balance;

        emit Burn(address(0), balance, totalBurned);
    }

    /**
     * @notice Performs an emergency withdrawal of non-VVV tokens
     * @dev Used to recover mistakenly sent ERC20s other than VVV
     * @param token The address of the ERC20 to withdraw
     * @param to The recipient that should receive the recovered tokens
     */
    function emergencyWithdraw(
        address token,
        address to
    ) external onlyOwner nonReentrant {
        require(token != address(0), "Token address cannot be zero");
        require(to != address(0), "Recipient address cannot be zero");

        require(token != address(vvvToken), "Cannot withdraw VVV tokens");

        IERC20 tokenContract = IERC20(token);
        uint256 amount = tokenContract.balanceOf(address(this));
        if (amount > 0) {
            tokenContract.safeTransfer(to, amount);
            emit EmergencyWithdrawal(token, amount, to);
        }
    }

    /**
     * @notice Returns the list of all contributors who have ever deposited
     * @return The array of contributor addresses
     */
    function getContributors() external view returns (address[] memory) {
        return contributors;
    }

    /**
     * @notice Returns the number of unique contributors
     * @return The count of addresses in the contributor set
     */
    function getContributorCount() external view returns (uint256) {
        return contributors.length;
    }

    /**
     * @notice Returns the current VVV balance held by this mind
     * @return The balance of VVV tokens
     */
    function getVVVBalance() external view returns (uint256) {
        return vvvToken.balanceOf(address(this));
    }

    /**
     * @notice Transfers mind ownership and emits the custom OwnerTransferred event
     * @param newOwner The address that should receive ownership
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        address previousOwner = owner();
        _transferOwnership(newOwner);
        emit OwnerTransferred(previousOwner, newOwner);
    }

    /**
     * @notice Internal helper that pulls VVV from a contributor and records their total contributions
     * @param contributor The address providing VVV
     * @param amount The amount of VVV to transfer and account for
     */
    function _deposit(address contributor, uint256 amount) private {
        if (amount == 0) {
            revert ZeroAmount();
        }

        IERC20 token = vvvToken;
        token.safeTransferFrom(contributor, address(this), amount);

        if (!isContributor[contributor]) {
            contributors.push(contributor);
            isContributor[contributor] = true;
        }

        uint256 newTotal = contributedBy[contributor] + amount;
        contributedBy[contributor] = newTotal;

        emit Deposit(contributor, amount, newTotal);
    }

    /**
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[50] private _gap;
}
