// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VeniceMind
 * @dev Mind subcontract that holds VVV tokens and allows burning them
 * @notice This contract accepts VVV deposits and allows the owner to burn the entire balance
 */
contract VeniceMind is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The VVV token contract address
    IERC20 public vvvToken;

    /// @notice Whether the contract has been initialized
    bool private initialized;

    /// @notice Total amount of VVV burned from this mind
    uint256 public totalBurned;

    /// @notice Mapping of contributor address to total amount burned by them
    mapping(address => uint256) public burnedBy;

    /// @notice Array of all contributors who have burned tokens
    address[] private contributors;

    /// @notice Mapping to track if an address is already in contributors array
    mapping(address => bool) private isContributor;

    /// @notice Event emitted when VVV tokens are burned
    /// @param contributor The address that contributed the tokens being burned
    /// @param amount The amount of VVV tokens burned
    /// @param totalBurned The new total amount burned from this mind
    /// @param contributorTotal The new total amount burned by this contributor
    event Burn(
        address indexed contributor,
        uint256 amount,
        uint256 totalBurned,
        uint256 contributorTotal
    );

    /// @notice Event emitted when ownership is transferred
    /// @param previousOwner The previous owner address
    /// @param newOwner The new owner address
    event OwnerTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Event emitted when non-VVV tokens are emergency withdrawn
    /// @param token The token contract address
    /// @param amount The amount withdrawn
    /// @param to The recipient address
    event EmergencyWithdrawal(
        address indexed token,
        uint256 amount,
        address indexed to
    );

    /// @notice Error thrown when trying to burn zero tokens
    error NoTokensToBurn();

    /// @notice Error thrown when trying to withdraw VVV tokens
    error CannotWithdrawVVV();

    /// @notice Error thrown when trying to initialize an already initialized contract
    error AlreadyInitialized();

    /**
     * @dev Constructor for direct deployment (tests) or implementation contract
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner
     * @notice For clones created via factory, use initialize() instead
     */
    constructor(address _vvvToken, address _owner) Ownable(_owner) {
        require(_vvvToken != address(0), "VVV token address cannot be zero");
        require(_owner != address(0), "Owner address cannot be zero");

        vvvToken = IERC20(_vvvToken);
        initialized = true; // Prevent initialize() from being called on direct deployments
    }

    /**
     * @notice Initializes the clone with VVV token and owner
     * @dev Can only be called once per clone
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner of this mind contract
     */
    function initialize(address _vvvToken, address _owner) external {
        require(_vvvToken != address(0), "VVV token address cannot be zero");
        require(_owner != address(0), "Owner address cannot be zero");
        if (initialized) {
            revert AlreadyInitialized();
        }

        initialized = true;
        vvvToken = IERC20(_vvvToken);
        _transferOwnership(_owner);
    }

    /**
     * @notice Burns all VVV tokens held by this contract
     * @dev Only the owner can call this function
     * @dev Uses reentrancy guard for security
     * @dev Records the burn amount for accounting purposes
     */
    function burn() external onlyOwner nonReentrant {
        uint256 balance = vvvToken.balanceOf(address(this));

        if (balance == 0) {
            revert NoTokensToBurn();
        }

        // Update accounting
        totalBurned += balance;

        // For accounting purposes, we attribute the burn to the caller
        // In practice, this would be the factory or admin calling burn
        address contributor = msg.sender;

        if (!isContributor[contributor]) {
            contributors.push(contributor);
            isContributor[contributor] = true;
        }

        burnedBy[contributor] += balance;

        // Burn tokens by transferring to a dedicated burn address
        // Using 0xdead as the standard burn address (address(0) is not allowed by ERC20)
        vvvToken.safeTransfer(
            address(0x000000000000000000000000000000000000dEaD),
            balance
        );

        emit Burn(contributor, balance, totalBurned, burnedBy[contributor]);
    }

    /**
     * @notice Burns VVV tokens and attributes them to a specific contributor
     * @dev Only the owner can call this function
     * @dev Uses reentrancy guard for security
     * @param contributor The address to attribute the burn to
     */
    function burnFor(address contributor) external onlyOwner nonReentrant {
        require(
            contributor != address(0),
            "Contributor address cannot be zero"
        );

        uint256 balance = vvvToken.balanceOf(address(this));

        if (balance == 0) {
            revert NoTokensToBurn();
        }

        // Update accounting
        totalBurned += balance;

        if (!isContributor[contributor]) {
            contributors.push(contributor);
            isContributor[contributor] = true;
        }

        burnedBy[contributor] += balance;

        // Burn tokens by transferring to a dedicated burn address
        // Using 0xdead as the standard burn address (address(0) is not allowed by ERC20)
        vvvToken.safeTransfer(
            address(0x000000000000000000000000000000000000dEaD),
            balance
        );

        emit Burn(contributor, balance, totalBurned, burnedBy[contributor]);
    }

    /**
     * @notice Emergency withdrawal of non-VVV tokens
     * @dev Only the owner can call this function
     * @dev Cannot withdraw VVV tokens
     * @param token The token contract address to withdraw
     * @param to The recipient address
     */
    function emergencyWithdraw(address token, address to) external onlyOwner {
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
     * @notice Get the list of all contributors
     * @return Array of contributor addresses
     */
    function getContributors() external view returns (address[] memory) {
        return contributors;
    }

    /**
     * @notice Get the number of contributors
     * @return The number of unique contributors
     */
    function getContributorCount() external view returns (uint256) {
        return contributors.length;
    }

    /**
     * @notice Get the current VVV balance of this contract
     * @return The current VVV token balance
     */
    function getVVVBalance() external view returns (uint256) {
        return vvvToken.balanceOf(address(this));
    }

    /**
     * @notice Override transferOwnership to emit custom event
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        address previousOwner = owner();
        _transferOwnership(newOwner);
        emit OwnerTransferred(previousOwner, newOwner);
    }
}
