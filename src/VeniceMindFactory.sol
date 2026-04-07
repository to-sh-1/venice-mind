// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeniceMind} from "./VeniceMind.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title VeniceMindFactory
 * @dev Master factory that creates mind subcontracts using ERC1967 proxies
 * @notice This contract manages the creation of mind burn contracts and tracks global statistics
 */
contract VeniceMindFactory is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
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
        address mindAddress;
        uint256 createdAt;
        uint256 totalBurned;
        string metadata;
    }

    /// @notice Event emitted when a new mind is created
    /// @param creator The address that created the mind
    /// @param mindId The unique ID of the mind
    /// @param mindAddress The deployed address of the mind contract
    /// @param metadata Optional metadata for the mind
    event MindCreated(address indexed creator, uint256 indexed mindId, address indexed mindAddress, string metadata);

    /// @notice Event emitted when a mind burns tokens
    /// @param mindId The ID of the mind that burned tokens
    /// @param amount The amount of tokens burned
    /// @param globalTotal The new global total burned
    event GlobalBurn(uint256 indexed mindId, uint256 amount, uint256 globalTotal);

    /// @notice Event emitted when the allowlist is updated
    /// @param account The account address
    /// @param allowed Whether the account is allowed to create minds
    event AllowlistUpdated(address indexed account, bool allowed);

    /// @notice Event emitted when allowlist is enabled/disabled
    /// @param enabled Whether the allowlist is enabled
    event AllowlistToggled(bool enabled);

    /// @notice Event emitted when a mind burn fails during burnFromMinds
    /// @param mindId The ID of the mind whose burn failed
    /// @param reason The revert reason
    event MindBurnFailed(uint256 indexed mindId, bytes reason);

    /// @notice Event emitted when a mind is skipped during burn operations
    /// @param mindId The ID of the mind that was skipped
    /// @param reason Human-readable reason the mind was skipped
    event MindBurnSkipped(uint256 indexed mindId, string reason);

    /// @notice Event emitted when a mind performs a swap from an input token into VVV
    /// @param mindId The ID of the mind that executed the swap
    /// @param inputToken The token that was swapped from
    /// @param inputAmount The amount of input token swapped
    /// @param vvvReceived The amount of VVV received by the mind
    /// @param aggregator The DEX aggregator/router used for execution
    event MindSwapToVVV(
        uint256 indexed mindId,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 vvvReceived,
        address indexed aggregator
    );

    /// @notice Event emitted when the mind implementation is updated
    /// @param newImplementation The new implementation contract address
    event MindImplementationUpdated(address indexed newImplementation);

    /// @notice Error thrown when a zero address is passed where a valid address is required
    error ZeroAddress();

    /// @notice Error thrown when allowlist is enabled and caller is not allowed
    error NotAllowedToCreateMind();

    /// @notice Error thrown when referencing a mind that does not exist
    error MindNotFound();

    /// @notice Error thrown when a mind is not managed by this factory
    error MindNotManagedByFactory();

    /// @notice Error thrown when the start index exceeds the mind array bounds
    error StartIndexOutOfBounds();

    /// @notice Error thrown when burnFromMinds is called with a zero batch size
    error ZeroBatchSize();

    /// @notice Error thrown when an implementation address is not a valid contract
    error InvalidImplementation();

    /// @notice Error thrown when renounceOwnership is called
    error RenounceOwnershipDisabled();

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
    function initialize(address _vvvToken, address _owner, address _mindImplementation) external initializer {
        if (_vvvToken == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_mindImplementation == address(0)) revert ZeroAddress();
        if (_mindImplementation.code.length == 0) {
            revert InvalidImplementation();
        }

        __Ownable_init(_owner);
        vvvToken = _vvvToken;
        mindImplementation = _mindImplementation;
    }

    /**
     * @notice Creates a new upgradeable mind instance and registers it
     * @param metadata Optional metadata string describing the mind
     * @return mindId The numeric identifier assigned to the new mind
     * @return mindAddress The address of the deployed proxy contract
     */
    function createMind(string calldata metadata) external nonReentrant returns (uint256 mindId, address mindAddress) {
        if (allowlistEnabled && !allowlist[msg.sender]) {
            revert NotAllowedToCreateMind();
        }

        // Increment mind counter
        mindId = ++mindCounter;

        // Deploy upgradeable mind proxy with initializer data
        bytes memory initData = abi.encodeWithSelector(VeniceMind.initialize.selector, vvvToken, owner(), address(this));
        mindAddress = address(new ERC1967Proxy(mindImplementation, initData));

        // Store mind information
        minds[mindId] = MindInfo({
            creator: msg.sender,
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
        if (mindAddr == address(0)) revert MindNotFound();

        VeniceMind mindContract = VeniceMind(mindAddr);
        if (mindContract.factory() != address(this)) {
            revert MindNotManagedByFactory();
        }

        uint256 totalBurnedBefore = mindContract.totalBurned();
        uint256 balanceBefore = mindContract.getVVVBalance();

        if (balanceBefore == 0) {
            emit MindBurnSkipped(mindId, "zero balance");
            return;
        }

        mindContract.burn();

        uint256 totalBurnedAfter = mindContract.totalBurned();
        uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

        uint256 newGlobalTotal = globalTotalBurned + actuallyBurned;
        globalTotalBurned = newGlobalTotal;
        mind.totalBurned = totalBurnedAfter;

        emit GlobalBurn(mindId, actuallyBurned, newGlobalTotal);
    }

    /**
     * @notice Burns balances from a paginated slice of minds
     * @dev Use startIndex=0 and batchSize=getMindCount() to burn all, or page through in batches
     * @param startIndex The index into mindIds to begin from (inclusive)
     * @param batchSize The maximum number of minds to process in this call
     */
    function burnFromMinds(uint256 startIndex, uint256 batchSize) external onlyOwner nonReentrant {
        if (batchSize == 0) revert ZeroBatchSize();
        uint256 length = mindIds.length;
        if (startIndex >= length) revert StartIndexOutOfBounds();

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > length) {
            endIndex = length;
        }

        uint256 currentGlobalTotal = globalTotalBurned;

        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 mindId = mindIds[i];
            MindInfo storage mind = minds[mindId];
            address mindAddr = mind.mindAddress;

            VeniceMind mindContract = VeniceMind(mindAddr);

            try mindContract.factory() returns (address f) {
                if (f != address(this)) {
                    emit MindBurnSkipped(mindId, "not managed by factory");
                    continue;
                }
            } catch {
                emit MindBurnSkipped(mindId, "factory check reverted");
                continue;
            }
            uint256 balanceBefore = mindContract.getVVVBalance();

            if (balanceBefore > 0) {
                uint256 totalBurnedBefore = mindContract.totalBurned();

                try mindContract.burn() {
                    uint256 totalBurnedAfter = mindContract.totalBurned();
                    uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

                    currentGlobalTotal += actuallyBurned;
                    mind.totalBurned = totalBurnedAfter;

                    emit GlobalBurn(mindId, actuallyBurned, currentGlobalTotal);
                } catch (bytes memory reason) {
                    emit MindBurnFailed(mindId, reason);
                }
            }
        }

        globalTotalBurned = currentGlobalTotal;
    }

    /**
     * @notice Swaps an input token held by a specific mind into VVV via the mind contract
     * @dev The factory owner orchestrates swaps while execution occurs in the target mind
     * @param mindId The identifier of the mind that should execute the swap
     * @param inputToken The token to swap from
     * @param inputAmount The amount of input token to swap
     * @param aggregator The aggregator/router contract to execute
     * @param swapCalldata Pre-built calldata for the aggregator call
     * @param minVVVOut The minimum acceptable VVV output (slippage protection)
     * @return vvvReceived The amount of VVV received by the mind
     */
    function swapMindToken(
        uint256 mindId,
        address inputToken,
        uint256 inputAmount,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minVVVOut
    ) external onlyOwner nonReentrant returns (uint256 vvvReceived) {
        address mindAddr = minds[mindId].mindAddress;
        if (mindAddr == address(0)) revert MindNotFound();

        VeniceMind mindContract = VeniceMind(mindAddr);
        if (mindContract.factory() != address(this)) {
            revert MindNotManagedByFactory();
        }

        vvvReceived = mindContract.swapToVVV(inputToken, inputAmount, aggregator, swapCalldata, minVVVOut);

        emit MindSwapToVVV(mindId, inputToken, inputAmount, vvvReceived, aggregator);
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
     * @notice Updates the implementation contract used for newly created minds
     * @param _newImplementation The address of the new mind implementation contract
     */
    function setMindImplementation(address _newImplementation) external onlyOwner {
        if (_newImplementation == address(0)) revert ZeroAddress();
        if (_newImplementation.code.length == 0) revert InvalidImplementation();
        mindImplementation = _newImplementation;
        emit MindImplementationUpdated(_newImplementation);
    }

    /**
     * @notice Returns the recorded information for a specific mind
     * @param mindId The identifier of the mind to query
     * @return mindInfo The stored struct with metadata and totals
     */
    function getMindInfo(uint256 mindId) external view returns (MindInfo memory mindInfo) {
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
    function getMindTotalBurned(uint256 mindId) external view returns (uint256) {
        // Direct storage read is already optimal
        return minds[mindId].totalBurned;
    }

    /**
     * @notice Sums the contributions of an address across all minds
     * @param contributor The address whose contributions should be aggregated
     * @return total The total recorded contribution amount
     */
    function getTotalContributedBy(address contributor) external view returns (uint256 total) {
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
        if (mindAddr == address(0)) revert MindNotFound();
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
            address mindAddr = minds[mindId].mindAddress;
            VeniceMind mindContract = VeniceMind(mindAddr);
            total += mindContract.getVVVBalance();
        }
    }

    /**
     * @notice Returns a paginated slice of mind identifiers
     * @param startIndex The index to begin from (inclusive)
     * @param batchSize The maximum number of IDs to return
     * @return ids The slice of mind IDs
     */
    function getMindIdsPaginated(uint256 startIndex, uint256 batchSize) external view returns (uint256[] memory ids) {
        uint256 length = mindIds.length;
        if (startIndex >= length) return new uint256[](0);

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > length) endIndex = length;

        uint256 resultLength = endIndex - startIndex;
        ids = new uint256[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            ids[i] = mindIds[startIndex + i];
        }
    }

    /**
     * @notice Sums the contributions of an address across a paginated slice of minds
     * @param contributor The address whose contributions should be aggregated
     * @param startIndex The index into mindIds to begin from (inclusive)
     * @param batchSize The maximum number of minds to query
     * @return total The total recorded contribution amount for the queried slice
     */
    function getTotalContributedByPaginated(address contributor, uint256 startIndex, uint256 batchSize)
        external
        view
        returns (uint256 total)
    {
        uint256 length = mindIds.length;
        if (startIndex >= length) return 0;

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > length) endIndex = length;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address mindAddr = minds[mindIds[i]].mindAddress;
            total += VeniceMind(mindAddr).contributedBy(contributor);
        }
    }

    /**
     * @notice Aggregates VVV balances across a paginated slice of minds
     * @param startIndex The index into mindIds to begin from (inclusive)
     * @param batchSize The maximum number of minds to query
     * @return total The sum of VVV held by the queried slice of minds
     */
    function getTotalVVVBalancePaginated(uint256 startIndex, uint256 batchSize) external view returns (uint256 total) {
        uint256 length = mindIds.length;
        if (startIndex >= length) return 0;

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > length) endIndex = length;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address mindAddr = minds[mindIds[i]].mindAddress;
            total += VeniceMind(mindAddr).getVVVBalance();
        }
    }

    /**
     * @notice Disabled to prevent accidental loss of ownership and upgradeability
     */
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /**
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) revert InvalidImplementation();
    }

    uint256[50] private _gap;
}
