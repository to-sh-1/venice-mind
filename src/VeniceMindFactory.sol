// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeniceMind} from "./VeniceMind.sol";
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
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title VeniceMindFactory
 * @dev Master factory that creates mind subcontracts using minimal proxy clones
 * @notice This contract manages the creation of mind burn contracts and tracks global statistics
 */
contract VeniceMindFactory is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Clones for address;

    /// @notice The implementation contract for mind burn contracts
    address public mindImplementation;

    /// @notice The VVV token contract address
    address public vvvToken;

    /// @notice Counter for mind IDs
    uint256 public mindCounter;

    /// @notice Global counter of total VVV burned across all minds
    uint256 public globalTotalBurned;

    /// @notice Optional allowlist for who can create minds
    mapping(address => bool) public allowlist;
    bool public allowlistEnabled;

    /// @notice Mapping of mind ID to mind information
    mapping(uint256 => MindInfo) public minds;

    /// @notice Array of all mind IDs
    uint256[] private mindIds;

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

    /**
     * @dev Constructor sets the VVV token address and deploys the implementation
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner of the factory
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory with token, owner, and implementation addresses
     * @param _vvvToken The ERC20 token address that all minds will accept
     * @param _owner The owner (typically Venice) with administrative powers
     * @param _mindImplementation The deployed implementation logic contract for minds
     */
    function initialize(
        address _vvvToken,
        address _owner,
        address _mindImplementation
    ) external initializer {
        require(_vvvToken != address(0), "VVV token address cannot be zero");
        require(_owner != address(0), "Owner address cannot be zero");
        require(
            _mindImplementation != address(0),
            "Mind implementation cannot be zero"
        );

        __Ownable_init(_owner);
        reentrancyGuardInit();
        vvvToken = _vvvToken;
        mindImplementation = _mindImplementation;
    }

    /**
     * @notice Creates a new upgradeable mind instance and registers it
     * @param metadata Optional metadata string describing the mind
     * @return mindId The numeric identifier assigned to the new mind
     * @return mindAddress The address of the deployed proxy contract
     */
    function createMind(
        string calldata metadata
    ) external returns (uint256 mindId, address mindAddress) {
        if (allowlistEnabled && !allowlist[msg.sender]) {
            revert NotAllowedToCreateMind();
        }

        // Increment mind counter
        mindId = ++mindCounter;

        // Deploy upgradeable mind proxy with initializer data
        bytes memory initData = abi.encodeWithSelector(
            VeniceMind.initialize.selector,
            vvvToken,
            owner(),
            address(this)
        );
        mindAddress = address(new ERC1967Proxy(mindImplementation, initData));

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
     * @notice Burns the full VVV balance from a specific mind
     * @param mindId The identifier of the mind to burn
     */
    function burnFromMind(uint256 mindId) external onlyOwner nonReentrant {
        MindInfo storage mind = minds[mindId];
        address mindAddr = mind.mindAddress;
        require(mindAddr != address(0), "Mind does not exist");

        VeniceMind mindContract = VeniceMind(mindAddr);

        // Get the actual burned amount from the mind contract before and after
        uint256 totalBurnedBefore = mindContract.totalBurned();
        uint256 balanceBefore = mindContract.getVVVBalance();

        if (balanceBefore > 0) {
            // Burn the tokens
            mindContract.burn();

            // Get the actual burned amount (handles any deposits that occurred between checks)
            uint256 totalBurnedAfter = mindContract.totalBurned();
            uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

            // Update global accounting based on what was actually burned
            uint256 newGlobalTotal = globalTotalBurned + actuallyBurned;
            globalTotalBurned = newGlobalTotal;
            mind.totalBurned = totalBurnedAfter; // Sync with actual contract state

            emit GlobalBurn(mindId, actuallyBurned, newGlobalTotal);
        }
    }

    /**
     * @notice Iterates all minds and burns their balances where possible
     * @dev Gas usage scales with the number of minds and balances
     */
    function burnFromAllMinds() external onlyOwner nonReentrant {
        uint256 length = mindIds.length;
        uint256 currentGlobalTotal = globalTotalBurned;

        for (uint256 i = 0; i < length; i++) {
            uint256 mindId = mindIds[i];
            MindInfo storage mind = minds[mindId];
            address mindAddr = mind.mindAddress;

            VeniceMind mindContract = VeniceMind(mindAddr);

            // Skip minds that are no longer managed by this factory
            if (mindContract.factory() != address(this)) {
                continue;
            }

            // Get the actual burned amount from the mind contract
            uint256 totalBurnedBefore = mindContract.totalBurned();
            uint256 balanceBefore = mindContract.getVVVBalance();

            if (balanceBefore > 0) {
                // Burn the tokens
                mindContract.burn();

                // Get the actual burned amount
                uint256 totalBurnedAfter = mindContract.totalBurned();
                uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

                // Update accounting based on what was actually burned
                currentGlobalTotal += actuallyBurned;
                mind.totalBurned = totalBurnedAfter; // Sync with actual contract state

                emit GlobalBurn(mindId, actuallyBurned, currentGlobalTotal);
            }
        }

        // Update global total once at the end (saves storage writes)
        globalTotalBurned = currentGlobalTotal;
    }

    /**
     * @notice Adds or removes an account from the mind creation allowlist
     * @param account The address to update
     * @param allowed Boolean indicating allowlist status
     */
    function updateAllowlist(address account, bool allowed) external onlyOwner {
        if (allowlist[account] == allowed) {
            return; // No change, save gas
        }
        allowlist[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    /**
     * @notice Enables or disables enforcement of the allowlist
     * @param enabled True to enable or false to disable the allowlist
     */
    function toggleAllowlist(bool enabled) external onlyOwner {
        if (allowlistEnabled == enabled) {
            return; // No change, save gas
        }
        allowlistEnabled = enabled;
        emit AllowlistToggled(enabled);
    }

    /**
     * @notice Returns the recorded information for a specific mind
     * @param mindId The identifier of the mind to query
     * @return mindInfo The stored struct with metadata and totals
     */
    function getMindInfo(
        uint256 mindId
    ) external view returns (MindInfo memory mindInfo) {
        return minds[mindId];
    }

    /**
     * @notice Returns the list of all mind identifiers
     * @return The array of mind IDs
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
     * @notice Returns the total burned amount tracked for a mind
     * @param mindId The identifier of the mind
     * @return The aggregate burned amount recorded for that mind
     */
    function getMindTotalBurned(
        uint256 mindId
    ) external view returns (uint256) {
        // Direct storage read is already optimal
        return minds[mindId].totalBurned;
    }

    /**
     * @notice Sums the contributions of an address across all minds
     * @param contributor The address whose contributions should be aggregated
     * @return total The total recorded contribution amount
     */
    function getTotalContributedBy(
        address contributor
    ) external view returns (uint256 total) {
        uint256 length = mindIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 mindId = mindIds[i];
            // Cache mind address to save storage read
            address mindAddr = minds[mindId].mindAddress;
            VeniceMind mindContract = VeniceMind(mindAddr);
            total += mindContract.contributedBy(contributor);
        }
    }

    /**
     * @notice Retrieves the live VVV balance for a specific mind contract
     * @param mindId The identifier of the mind to query
     * @return The current VVV token balance at the mind address
     */
    function getMindVVVBalance(uint256 mindId) external view returns (uint256) {
        address mindAddr = minds[mindId].mindAddress;
        require(mindAddr != address(0), "Mind does not exist");
        VeniceMind mindContract = VeniceMind(mindAddr);
        return mindContract.getVVVBalance();
    }

    /**
     * @notice Aggregates the VVV balances across all minds
     * @return total The sum of VVV held by every mind
     */
    function getTotalVVVBalance() external view returns (uint256 total) {
        uint256 length = mindIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 mindId = mindIds[i];
            // Cache mind address to save storage read
            address mindAddr = minds[mindId].mindAddress;
            VeniceMind mindContract = VeniceMind(mindAddr);
            total += mindContract.getVVVBalance();
        }
    }

    /**
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[50] private _gap;
}
