// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeniceMind} from "./VeniceMind.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VeniceMindFactory
 * @dev Master factory that creates mind subcontracts using ERC1967 proxies
 * @notice This contract manages the creation of mind burn contracts and tracks global statistics
 */
contract VeniceMindFactory is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    /// @notice Initial value of {maxCreateBatchSize}
    /// @dev A 25-mind batch measured about 7.0M gas including intrinsic and calldata costs.
    uint256 public constant DEFAULT_MAX_CREATE_BATCH_SIZE = 25;

    /// @notice The implementation contract for mind burn contracts
    address public mindImplementation;

    /// @notice The VVV token contract address
    address public vvvToken;

    /// @notice Global counter of total VVV burned across all minds
    uint256 public globalTotalBurned;

    /// @notice Optional allowlist for who can create minds
    mapping(address => bool) public allowlist;
    bool public allowlistEnabled;

    /// @notice Struct containing mind information
    struct MindInfo {
        address creator;
        address mindAddress;
        uint256 createdAt;
        uint256 totalBurned;
    }

    /// @dev Mind numbers in creation order. Array positions are used only for pagination.
    uint256[] private mindNumbersByIndex;

    /// @notice Mapping of mind number to mind information
    /// @dev A zero `mindAddress` means the number is not registered.
    ///      Kept in a mapping so future upgrades can append fields to `MindInfo` without shifting records.
    mapping(uint256 => MindInfo) public minds;

    /// @notice Event emitted when a new mind is created
    /// @param creator The address that created the mind
    /// @param mindNumber The externally supplied unique number of the mind
    /// @param mindAddress The deployed address of the mind contract
    event MindCreated(address indexed creator, uint256 indexed mindNumber, address indexed mindAddress);

    /// @notice Event emitted when a mind burns tokens
    /// @param mindNumber The number of the mind that burned tokens
    /// @param amount The amount of tokens burned
    /// @param globalTotal The new global total burned
    event GlobalBurn(uint256 indexed mindNumber, uint256 amount, uint256 globalTotal);

    /// @notice Event emitted when the allowlist is updated
    /// @param account The account address
    /// @param allowed Whether the account is allowed to create minds
    event AllowlistUpdated(address indexed account, bool allowed);

    /// @notice Event emitted when allowlist is enabled/disabled
    /// @param enabled Whether the allowlist is enabled
    event AllowlistToggled(bool enabled);

    /// @notice Event emitted when a mind burn fails during burnFromMinds
    /// @param mindNumber The number of the mind whose burn failed
    /// @param reason The revert reason
    event MindBurnFailed(uint256 indexed mindNumber, bytes reason);

    /// @notice Event emitted when a mind is skipped during burn operations
    /// @param mindNumber The number of the mind that was skipped
    /// @param reason Human-readable reason the mind was skipped
    event MindBurnSkipped(uint256 indexed mindNumber, string reason);

    /// @notice Event emitted when a mind performs a swap from an input token into VVV
    /// @param mindNumber The number of the mind that executed the swap
    /// @param inputToken The token that was swapped from
    /// @param inputAmount The decrease in the mind's input-token balance across the swap, which can
    ///        differ from the approved amount passed to {swapMindToken}
    /// @param vvvReceived The amount of VVV received by the mind
    /// @param aggregator The DEX aggregator/router used for execution
    event MindSwapToVVV(
        uint256 indexed mindNumber,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 vvvReceived,
        address indexed aggregator
    );

    /// @notice Event emitted when the mind implementation is updated
    /// @param newImplementation The new implementation contract address
    event MindImplementationUpdated(address indexed newImplementation);

    /// @notice Event emitted when the burn operator is updated
    /// @param previousOperator The previous burn operator
    /// @param newOperator The new burn operator
    event BurnOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    /// @notice Event emitted when the maximum creation batch size is updated
    /// @param previousSize The previous maximum batch size
    /// @param newSize The new maximum batch size
    event MaxCreateBatchSizeUpdated(uint256 previousSize, uint256 newSize);

    /// @notice Error thrown when a zero address is passed where a valid address is required
    error ZeroAddress();

    /// @notice Error thrown when allowlist is enabled and caller is not allowed
    error NotAllowedToCreateMind();

    /// @notice Error thrown when referencing a mind that does not exist
    error MindNotFound();

    /// @notice Error thrown when an empty creation batch is supplied
    error EmptyCreateBatch();

    /// @notice Error thrown when a creation batch exceeds {maxCreateBatchSize}
    error CreateBatchTooLarge(uint256 requested, uint256 maximum);

    /// @notice Error thrown when a mind is not managed by this factory
    error MindNotManagedByFactory();

    /// @notice Error thrown when the start index exceeds the mind count
    error StartIndexOutOfBounds();

    /// @notice Error thrown when burnFromMinds or setMaxCreateBatchSize is given a zero batch size
    error ZeroBatchSize();

    /// @notice Error thrown when an implementation address is not a valid contract
    error InvalidImplementation();

    /// @notice Error thrown when renounceOwnership is called
    error RenounceOwnershipDisabled();

    /// @notice Error thrown when a caller other than the burn operator attempts to burn
    error UnauthorizedBurnOperator();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory with token, owner, and implementation addresses
     * @param _vvvToken The ERC20 token address that all minds will accept
     * @param _owner The owner (typically Venice) with administrative powers
     * @param _mindImplementation The deployed implementation logic contract for minds
     * @param _burnOperator The operational wallet authorized to initiate burns
     */
    function initialize(address _vvvToken, address _owner, address _mindImplementation, address _burnOperator)
        external
        initializer
    {
        if (_vvvToken == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_mindImplementation == address(0)) revert ZeroAddress();
        if (_burnOperator == address(0)) revert ZeroAddress();
        if (_mindImplementation.code.length == 0) {
            revert InvalidImplementation();
        }

        __Ownable_init(_owner);
        vvvToken = _vvvToken;
        mindImplementation = _mindImplementation;
        burnOperator = _burnOperator;
        allowlistEnabled = true;
        maxCreateBatchSize = DEFAULT_MAX_CREATE_BATCH_SIZE;
    }

    /**
     * @notice Atomically creates or resolves one or more upgradeable mind instances
     * @dev Existing and repeated mind numbers resolve to their original addresses unchanged
     * @param mindNumbers The externally supplied unique numbers for the minds
     * @return mindAddresses The resolved mind addresses in input order
     */
    function createMinds(uint256[] calldata mindNumbers)
        external
        nonReentrant
        returns (address[] memory mindAddresses)
    {
        if (allowlistEnabled && !allowlist[msg.sender]) {
            revert NotAllowedToCreateMind();
        }

        uint256 length = mindNumbers.length;
        if (length == 0) revert EmptyCreateBatch();
        if (length > maxCreateBatchSize) revert CreateBatchTooLarge(length, maxCreateBatchSize);

        bytes memory initData = abi.encodeWithSelector(VeniceMind.initialize.selector, vvvToken, owner(), address(this));
        mindAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 mindNumber = mindNumbers[i];
            address mindAddress = minds[mindNumber].mindAddress;
            if (mindAddress == address(0)) {
                mindAddress = address(new ERC1967Proxy{salt: bytes32(mindNumber)}(mindImplementation, initData));
                minds[mindNumber] = MindInfo({
                    creator: msg.sender, mindAddress: mindAddress, createdAt: block.timestamp, totalBurned: 0
                });
                mindNumbersByIndex.push(mindNumber);
                emit MindCreated(msg.sender, mindNumber, mindAddress);
            }
            mindAddresses[i] = mindAddress;
        }
    }

    /**
     * @notice Burns the full VVV balance from a specific mind
     * @param mindNumber The number of the mind to burn
     */
    function burnFromMind(uint256 mindNumber) external onlyBurnOperator nonReentrant {
        MindInfo storage mind = minds[mindNumber];
        address mindAddr = mind.mindAddress;
        if (mindAddr == address(0)) revert MindNotFound();

        VeniceMind mindContract = VeniceMind(mindAddr);
        if (mindContract.factory() != address(this)) {
            revert MindNotManagedByFactory();
        }

        uint256 totalBurnedBefore = mindContract.totalBurned();
        uint256 balanceBefore = mindContract.getVVVBalance();

        if (balanceBefore == 0) {
            emit MindBurnSkipped(mindNumber, "zero balance");
            return;
        }

        mindContract.burn();

        uint256 totalBurnedAfter = mindContract.totalBurned();
        uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

        uint256 newGlobalTotal = globalTotalBurned + actuallyBurned;
        globalTotalBurned = newGlobalTotal;
        mind.totalBurned = totalBurnedAfter;

        emit GlobalBurn(mindNumber, actuallyBurned, newGlobalTotal);
    }

    /**
     * @notice Burns balances from a contiguous slice of minds
     * @dev `startIndex` is a 0-based creation-order index. If the requested window exceeds
     *      the current mind count, the end is clamped.
     *      Each mind holding VVV costs about 73.4k gas on its first burn and 39.1k afterward, so a
     *      window above roughly 225 minds can exceed Base's 16,777,216 per-transaction gas cap.
     *      Burn every mind by iterating windows of at most 150.
     * @param startIndex The 0-based creation index of the first mind to process
     * @param batchSize The maximum number of minds to process in this call
     */
    function burnFromMinds(uint256 startIndex, uint256 batchSize) external onlyBurnOperator nonReentrant {
        if (batchSize == 0) revert ZeroBatchSize();
        uint256 length = mindNumbersByIndex.length;
        if (startIndex >= length) revert StartIndexOutOfBounds();

        uint256 endIndex = length;
        if (batchSize < length - startIndex) {
            endIndex = startIndex + batchSize;
        }

        uint256 currentGlobalTotal = globalTotalBurned;

        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 mindNumber = mindNumbersByIndex[i];
            MindInfo storage mind = minds[mindNumber];
            address mindAddr = mind.mindAddress;

            VeniceMind mindContract = VeniceMind(mindAddr);

            try mindContract.factory() returns (address f) {
                if (f != address(this)) {
                    emit MindBurnSkipped(mindNumber, "not managed by factory");
                    continue;
                }
            } catch {
                emit MindBurnSkipped(mindNumber, "factory check reverted");
                continue;
            }
            uint256 balanceBefore = mindContract.getVVVBalance();

            if (balanceBefore == 0) {
                emit MindBurnSkipped(mindNumber, "zero balance");
                continue;
            }

            uint256 totalBurnedBefore = mindContract.totalBurned();

            try mindContract.burn() {
                uint256 totalBurnedAfter = mindContract.totalBurned();
                uint256 actuallyBurned = totalBurnedAfter - totalBurnedBefore;

                currentGlobalTotal += actuallyBurned;
                mind.totalBurned = totalBurnedAfter;

                emit GlobalBurn(mindNumber, actuallyBurned, currentGlobalTotal);
            } catch (bytes memory reason) {
                emit MindBurnFailed(mindNumber, reason);
            }
        }

        globalTotalBurned = currentGlobalTotal;
    }

    /**
     * @notice Swaps an input token held by a specific mind into VVV via the mind contract
     * @dev The factory owner orchestrates swaps while execution occurs in the target mind
     * @param mindNumber The number of the mind that should execute the swap
     * @param inputToken The token to swap from
     * @param inputAmount The amount of input token to swap
     * @param aggregator The aggregator/router contract to execute
     * @param swapCalldata Pre-built calldata for the aggregator call
     * @param minVVVOut The minimum acceptable VVV output (slippage protection)
     * @return vvvReceived The amount of VVV received by the mind
     */
    function swapMindToken(
        uint256 mindNumber,
        address inputToken,
        uint256 inputAmount,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minVVVOut
    ) external onlyOwner nonReentrant returns (uint256 vvvReceived) {
        address mindAddr = minds[mindNumber].mindAddress;
        if (mindAddr == address(0)) revert MindNotFound();

        VeniceMind mindContract = VeniceMind(mindAddr);
        if (mindContract.factory() != address(this)) {
            revert MindNotManagedByFactory();
        }
        if (inputToken == address(0)) revert ZeroAddress();

        uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(mindAddr);

        vvvReceived = mindContract.swapToVVV(inputToken, inputAmount, aggregator, swapCalldata, minVVVOut);

        uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(mindAddr);
        uint256 inputSpent = inputBalanceBefore > inputBalanceAfter ? inputBalanceBefore - inputBalanceAfter : 0;

        emit MindSwapToVVV(mindNumber, inputToken, inputSpent, vvvReceived, aggregator);
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
     * @notice Updates the operational wallet authorized to initiate burns
     * @param newOperator The new burn operator address
     */
    function setBurnOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit BurnOperatorUpdated(burnOperator, newOperator);
        burnOperator = newOperator;
    }

    /**
     * @notice Updates the maximum number of entries accepted by {createMinds}
     * @dev No upper bound is enforced. A batch whose gas exceeds the chain's per-transaction cap
     *      reverts as a whole, so callers must size batches for the target chain.
     * @param newSize The new maximum, which must be nonzero
     */
    function setMaxCreateBatchSize(uint256 newSize) external onlyOwner {
        if (newSize == 0) revert ZeroBatchSize();
        emit MaxCreateBatchSizeUpdated(maxCreateBatchSize, newSize);
        maxCreateBatchSize = newSize;
    }

    /**
     * @notice Returns the recorded information for a specific mind
     * @param mindNumber The number of the mind to query
     * @return mindInfo The stored struct with creator, address, creation time, and burn total
     */
    function getMindInfo(uint256 mindNumber) external view returns (MindInfo memory mindInfo) {
        return minds[mindNumber];
    }

    /**
     * @notice Returns all mind numbers in creation order
     * @return mindNumbers The array of externally supplied mind numbers
     */
    function getMindNumbers() external view returns (uint256[] memory mindNumbers) {
        return mindNumbersByIndex;
    }

    /**
     * @notice Get the total number of minds created
     * @return The number of minds in the creation-order registry
     */
    function getMindCount() external view returns (uint256) {
        return mindNumbersByIndex.length;
    }

    /**
     * @notice Returns the total burned amount tracked for a mind
     * @param mindNumber The number of the mind
     * @return The aggregate burned amount recorded for that mind
     */
    function getMindTotalBurned(uint256 mindNumber) external view returns (uint256) {
        return minds[mindNumber].totalBurned;
    }

    /**
     * @notice Retrieves the live VVV balance for a specific mind contract
     * @param mindNumber The number of the mind to query
     * @return The current VVV token balance at the mind address
     */
    function getMindVVVBalance(uint256 mindNumber) external view returns (uint256) {
        address mindAddr = minds[mindNumber].mindAddress;
        if (mindAddr == address(0)) revert MindNotFound();
        VeniceMind mindContract = VeniceMind(mindAddr);
        return mindContract.getVVVBalance();
    }

    /**
     * @notice Returns a paginated slice of mind numbers in creation order
     * @param startIndex The 0-based index to begin from (inclusive)
     * @param batchSize The maximum number of mind numbers to return
     * @return mindNumbers The slice of externally supplied mind numbers
     */
    function getMindNumbersPaginated(uint256 startIndex, uint256 batchSize)
        external
        view
        returns (uint256[] memory mindNumbers)
    {
        uint256 length = mindNumbersByIndex.length;
        if (startIndex >= length) return new uint256[](0);

        uint256 endIndex = length;
        if (batchSize < length - startIndex) endIndex = startIndex + batchSize;

        uint256 resultLength = endIndex - startIndex;
        mindNumbers = new uint256[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            mindNumbers[i] = mindNumbersByIndex[startIndex + i];
        }
    }

    /**
     * @notice Sums the contributions of an address across a paginated slice of minds
     * @param contributor The address whose contributions should be aggregated
     * @param startIndex The 0-based creation index of the first mind to query
     * @param batchSize The maximum number of minds to query
     * @return total The total recorded contribution amount for the queried slice
     */
    function getTotalContributedByPaginated(address contributor, uint256 startIndex, uint256 batchSize)
        external
        view
        returns (uint256 total)
    {
        uint256 length = mindNumbersByIndex.length;
        if (startIndex >= length) return 0;

        uint256 endIndex = length;
        if (batchSize < length - startIndex) endIndex = startIndex + batchSize;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address mindAddr = minds[mindNumbersByIndex[i]].mindAddress;
            total += VeniceMind(mindAddr).contributedBy(contributor);
        }
    }

    /**
     * @notice Aggregates VVV balances across a paginated slice of minds
     * @param startIndex The 0-based creation index of the first mind to query
     * @param batchSize The maximum number of minds to query
     * @return total The sum of VVV held by the queried slice of minds
     */
    function getTotalVVVBalancePaginated(uint256 startIndex, uint256 batchSize) external view returns (uint256 total) {
        uint256 length = mindNumbersByIndex.length;
        if (startIndex >= length) return 0;

        uint256 endIndex = length;
        if (batchSize < length - startIndex) endIndex = startIndex + batchSize;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address mindAddr = minds[mindNumbersByIndex[i]].mindAddress;
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

    /**
     * @dev Restricts burn initiation to the dedicated operational wallet.
     */
    modifier onlyBurnOperator() {
        if (msg.sender != burnOperator) revert UnauthorizedBurnOperator();
        _;
    }

    /// @notice Operational wallet authorized to initiate burns
    address public burnOperator;

    /// @notice Maximum number of entries accepted by {createMinds}
    uint256 public maxCreateBatchSize;

    uint256[48] private _gap;
}
