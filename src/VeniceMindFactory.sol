// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeniceMind} from "./VeniceMind.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title VeniceMindFactory
 * @dev Master factory that creates mind subcontracts using minimal proxy clones
 * @notice This contract manages the creation of mind burn contracts and tracks global statistics
 */
contract VeniceMindFactory is Ownable, ReentrancyGuard {
    using Clones for address;

    /// @notice The implementation contract for mind burn contracts
    VeniceMind public immutable mindImplementation;

    /// @notice The VVV token contract address
    address public immutable vvvToken;

    /// @notice Global counter of total VVV burned across all minds
    uint256 public globalTotalBurned;

    /// @notice Counter for mind IDs
    uint256 public mindCounter;

    /// @notice Mapping of mind ID to mind information
    mapping(uint256 => MindInfo) public minds;

    /// @notice Array of all mind IDs
    uint256[] private mindIds;

    /// @notice Optional allowlist for who can create minds
    mapping(address => bool) public allowlist;
    bool public allowlistEnabled;

    /// @notice Struct containing mind information
    struct MindInfo {
        address creator;
        uint256 mindId;
        address mindAddress;
        uint256 createdAt;
        uint256 totalBurned;
        string metadata; // Optional metadata for the mind
    }

    /// @notice Event emitted when a new mind is created
    /// @param creator The address that created the mind
    /// @param mindId The unique ID of the mind
    /// @param mindAddress The deployed address of the mind contract
    /// @param metadata Optional metadata for the mind
    event MindCreated(
        address indexed creator,
        uint256 indexed mindId,
        address indexed mindAddress,
        string metadata
    );

    /// @notice Event emitted when a mind burns tokens
    /// @param mindId The ID of the mind that burned tokens
    /// @param amount The amount of tokens burned
    /// @param globalTotal The new global total burned
    event GlobalBurn(
        uint256 indexed mindId,
        uint256 amount,
        uint256 globalTotal
    );

    /// @notice Event emitted when the allowlist is updated
    /// @param account The account address
    /// @param allowed Whether the account is allowed to create minds
    event AllowlistUpdated(address indexed account, bool allowed);

    /// @notice Event emitted when allowlist is enabled/disabled
    /// @param enabled Whether the allowlist is enabled
    event AllowlistToggled(bool enabled);

    /// @notice Error thrown when allowlist is enabled and caller is not allowed
    error NotAllowedToCreateMind();

    /// @notice Error thrown when trying to create a mind with invalid parameters
    error InvalidMindParameters();

    /**
     * @dev Constructor sets the VVV token address and deploys the implementation
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner of the factory
     */
    constructor(address _vvvToken, address _owner) Ownable(_owner) {
        require(_vvvToken != address(0), "VVV token address cannot be zero");
        require(_owner != address(0), "Owner address cannot be zero");

        vvvToken = _vvvToken;

        // Deploy the implementation contract
        mindImplementation = new VeniceMindBurn(_vvvToken, address(this));
    }

    /**
     * @notice Creates a new mind burn contract
     * @dev Uses minimal proxy clone for gas efficiency
     * @param metadata Optional metadata for the mind
     * @return mindId The ID of the created mind
     * @return mindAddress The address of the created mind contract
     */
    function createMind(
        string calldata metadata
    ) external returns (uint256 mindId, address mindAddress) {
        if (allowlistEnabled && !allowlist[msg.sender]) {
            revert NotAllowedToCreateMind();
        }

        // Increment mind counter
        mindId = ++mindCounter;

        // Create minimal proxy clone
        mindAddress = address(mindImplementation).clone();

        // Initialize the clone with the factory as owner initially
        // The factory owner (Venice) can later transfer ownership to multisigs
        VeniceMindBurn(mindAddress).transferOwnership(address(this));

        // Store mind information
        minds[mindId] = MindInfo({
            creator: msg.sender,
            mindId: mindId,
            mindAddress: mindAddress,
            createdAt: block.timestamp,
            totalBurned: 0,
            metadata: metadata
        });

        mindIds.push(mindId);

        emit MindCreated(msg.sender, mindId, mindAddress, metadata);

        return (mindId, mindAddress);
    }

    /**
     * @notice Burns all VVV tokens from a specific mind
     * @dev Only the factory owner can call this function
     * @param mindId The ID of the mind to burn tokens from
     */
    function burnFromMind(uint256 mindId) external onlyOwner nonReentrant {
        MindInfo storage mind = minds[mindId];
        require(mind.mindAddress != address(0), "Mind does not exist");

        VeniceMindBurn mindContract = VeniceMindBurn(mind.mindAddress);

        // Get the current balance before burning
        uint256 balanceBefore = mindContract.getVVVBalance();

        if (balanceBefore > 0) {
            // Burn the tokens
            mindContract.burn();

            // Update global accounting
            globalTotalBurned += balanceBefore;
            mind.totalBurned += balanceBefore;

            emit GlobalBurn(mindId, balanceBefore, globalTotalBurned);
        }
    }

    /**
     * @notice Burns all VVV tokens from all minds in one transaction
     * @dev Only the owner can call this function
     * @dev Uses reentrancy guard for security
     */
    function burnFromAllMinds() external onlyOwner nonReentrant {
        uint256 totalBurnedInBatch = 0;

        for (uint256 i = 0; i < mindIds.length; i++) {
            uint256 mindId = mindIds[i];
            MindInfo storage mind = minds[mindId];

            VeniceMindBurn mindContract = VeniceMindBurn(mind.mindAddress);
            uint256 balanceBefore = mindContract.getVVVBalance();

            if (balanceBefore > 0) {
                // Burn the tokens
                mindContract.burn();

                // Update accounting
                globalTotalBurned += balanceBefore;
                mind.totalBurned += balanceBefore;
                totalBurnedInBatch += balanceBefore;

                emit GlobalBurn(mindId, balanceBefore, globalTotalBurned);
            }
        }
    }

    /**
     * @notice Updates the allowlist for mind creation
     * @dev Only the owner can call this function
     * @param account The account address to update
     * @param allowed Whether the account is allowed to create minds
     */
    function updateAllowlist(address account, bool allowed) external onlyOwner {
        allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    /**
     * @notice Enables or disables the allowlist
     * @dev Only the owner can call this function
     * @param enabled Whether to enable the allowlist
     */
    function toggleAllowlist(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistToggled(enabled);
    }

    /**
     * @notice Get information about a specific mind
     * @param mindId The ID of the mind
     * @return mindInfo The mind information struct
     */
    function getMindInfo(
        uint256 mindId
    ) external view returns (MindInfo memory mindInfo) {
        return minds[mindId];
    }

    /**
     * @notice Get all mind IDs
     * @return Array of all mind IDs
     */
    function getMindIds() external view returns (uint256[] memory) {
        return mindIds;
    }

    /**
     * @notice Get the total number of minds created
     * @return The number of minds created
     */
    function getMindCount() external view returns (uint256) {
        return mindIds.length;
    }

    /**
     * @notice Get the total burned amount for a specific mind
     * @param mindId The ID of the mind
     * @return The total amount burned from this mind
     */
    function getMindTotalBurned(
        uint256 mindId
    ) external view returns (uint256) {
        return minds[mindId].totalBurned;
    }

    /**
     * @notice Get the total burned amount by a specific contributor across all minds
     * @param contributor The contributor address
     * @return total The total amount burned by this contributor
     */
    function getTotalBurnedBy(
        address contributor
    ) external view returns (uint256 total) {
        for (uint256 i = 0; i < mindIds.length; i++) {
            uint256 mindId = mindIds[i];
            VeniceMindBurn mindContract = VeniceMindBurn(
                minds[mindId].mindAddress
            );
            total += mindContract.burnedBy(contributor);
        }
    }

    /**
     * @notice Get the current VVV balance of a specific mind
     * @param mindId The ID of the mind
     * @return The current VVV balance of the mind
     */
    function getMindVVVBalance(uint256 mindId) external view returns (uint256) {
        require(minds[mindId].mindAddress != address(0), "Mind does not exist");
        VeniceMindBurn mindContract = VeniceMindBurn(minds[mindId].mindAddress);
        return mindContract.getVVVBalance();
    }

    /**
     * @notice Get the current VVV balance across all minds
     * @return total The total VVV balance across all minds
     */
    function getTotalVVVBalance() external view returns (uint256 total) {
        for (uint256 i = 0; i < mindIds.length; i++) {
            uint256 mindId = mindIds[i];
            VeniceMindBurn mindContract = VeniceMindBurn(
                minds[mindId].mindAddress
            );
            total += mindContract.getVVVBalance();
        }
    }

    /**
     * @notice Transfer ownership of a mind to a multisig
     * @dev Only the factory owner can call this function
     * @param mindId The ID of the mind
     * @param newOwner The new owner address (multisig)
     */
    function transferMindOwnership(
        uint256 mindId,
        address newOwner
    ) external onlyOwner {
        require(minds[mindId].mindAddress != address(0), "Mind does not exist");
        require(newOwner != address(0), "New owner cannot be zero address");

        VeniceMindBurn mindContract = VeniceMindBurn(minds[mindId].mindAddress);
        mindContract.transferOwnership(newOwner);
    }

    /**
     * @notice Emergency withdrawal of non-VVV tokens from a specific mind
     * @dev Only the owner can call this function
     * @param mindId The ID of the mind
     * @param token The token contract address to withdraw
     * @param to The recipient address
     */
    function emergencyWithdrawFromMind(
        uint256 mindId,
        address token,
        address to
    ) external onlyOwner {
        require(minds[mindId].mindAddress != address(0), "Mind does not exist");
        VeniceMindBurn mindContract = VeniceMindBurn(minds[mindId].mindAddress);
        mindContract.emergencyWithdraw(token, to);
    }
}
