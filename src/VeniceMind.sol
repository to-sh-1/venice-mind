// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title VeniceMind
 * @dev Mind subcontract that tracks VVV deposits and allows the owner to burn accounted balances
 */
contract VeniceMind is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The VVV token contract address
    IERC20 public vvvToken;

    /// @notice Total amount of VVV burned from this mind
    uint256 public totalBurned;

    /// @notice Factory contract that deployed this mind (authorized for certain operations)
    address public factory;

    /// @notice Burn address constant
    address private constant BURN_ADDRESS = address(0);

    /// @notice Mapping of contributor address to total amount contributed
    mapping(address => uint256) public contributedBy;

    /// @notice Array of all contributors who have interacted with this mind
    address[] private contributors;

    /// @notice Mapping to track if an address is already in contributors array
    mapping(address => bool) private isContributor;

    /// @notice Total amount of VVV deposited into this mind (via deposit())
    uint256 public totalDeposited;

    /// @notice Total amount of VVV received via swaps (not attributed to any contributor)
    uint256 public totalSwapped;

    /// @notice Event emitted when VVV tokens are deposited
    event Deposit(address indexed contributor, uint256 amount, uint256 totalContributed);

    /// @notice Event emitted when VVV tokens are burned
    event Burn(address indexed caller, uint256 amount, uint256 totalBurned);

    /// @notice Event emitted when tokens are withdrawn via emergencyWithdraw
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);

    /// @notice Event emitted when this mind swaps an ERC20 token into VVV
    event SwappedToVVV(
        address indexed inputToken, uint256 inputAmount, uint256 vvvReceived, address indexed aggregator
    );

    /// @notice Error thrown when a zero address is passed where a valid address is required
    error ZeroAddress();

    /// @notice Error thrown when trying to burn zero tokens
    error NoTokensToBurn();

    /// @notice Error thrown when an unauthorized caller attempts a restricted action
    error UnauthorizedCaller();

    /// @notice Error thrown when attempting to deposit zero tokens
    error ZeroAmount();

    /// @notice Error thrown when a DEX aggregator swap call fails
    error SwapFailed();

    /// @notice Error thrown when the swap output is below the minimum acceptable amount
    error SlippageExceeded(uint256 received, uint256 minimum);

    /// @notice Error thrown when emergency withdraw targets the VVV token
    error CannotWithdrawVVV();

    /// @notice Error thrown when attempting to swap from the VVV token itself
    error CannotSwapFromVVV();

    /// @notice Error thrown when renounceOwnership is called
    error RenounceOwnershipDisabled();

    /// @notice Error thrown when emergency withdraw finds no token balance
    error NoTokensToWithdraw();

    /// @notice Error thrown when an upgrade target is not a valid contract
    error InvalidImplementation();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the clone with token and ownership configuration
     * @param _vvvToken The VVV token contract address
     * @param _owner The initial owner of the mind
     * @param _factory The factory contract authorized to manage this mind
     */
    function initialize(address _vvvToken, address _owner, address _factory) external initializer {
        if (_vvvToken == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        vvvToken = IERC20(_vvvToken);
        factory = _factory;
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
    function burn() external onlyFactory nonReentrant {
        IERC20 token = vvvToken;
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) {
            revert NoTokensToBurn();
        }

        token.safeTransfer(BURN_ADDRESS, balance);
        totalBurned += balance;

        emit Burn(msg.sender, balance, totalBurned);
    }

    /**
     * @notice Performs an emergency withdrawal of non-VVV tokens
     * @dev Used to recover mistakenly sent ERC20s other than VVV
     * @param token The address of the ERC20 to withdraw
     * @param to The recipient that should receive the recovered tokens
     */
    function emergencyWithdraw(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (token == address(vvvToken)) revert CannotWithdrawVVV();

        IERC20 tokenContract = IERC20(token);
        uint256 amount = tokenContract.balanceOf(address(this));
        if (amount == 0) revert NoTokensToWithdraw();

        tokenContract.safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, amount, to);
    }

    /**
     * @notice Swaps a token balance held by this mind into VVV via a DEX aggregator
     * @dev Callable only by the factory to centralize admin orchestration in VeniceMindFactory
     * @dev Uses 0x aggregator to swap the input token into VVV
     * @param inputToken The token to swap from
     * @param inputAmount The amount of input tokens to swap
     * @param aggregator The aggregator/router contract to call
     * @param swapCalldata Pre-built calldata for aggregator execution
     * @param minVVVOut The minimum acceptable VVV output
     * @return vvvReceived The VVV amount received by this mind
     */
    function swapToVVV(
        address inputToken,
        uint256 inputAmount,
        address aggregator,
        bytes calldata swapCalldata,
        uint256 minVVVOut
    ) external onlyOwnerOrFactory nonReentrant returns (uint256 vvvReceived) {
        if (inputToken == address(0)) revert ZeroAddress();
        if (inputToken == address(vvvToken)) revert CannotSwapFromVVV();
        if (aggregator == address(0)) revert ZeroAddress();
        if (inputAmount == 0) {
            revert ZeroAmount();
        }

        IERC20 inputTokenContract = IERC20(inputToken);
        IERC20 token = vvvToken;
        uint256 vvvBalanceBefore = token.balanceOf(address(this));

        inputTokenContract.forceApprove(aggregator, inputAmount);

        (bool success,) = aggregator.call(swapCalldata);
        if (!success) {
            revert SwapFailed();
        }

        vvvReceived = token.balanceOf(address(this)) - vvvBalanceBefore;
        if (vvvReceived < minVVVOut) {
            revert SlippageExceeded(vvvReceived, minVVVOut);
        }

        totalSwapped += vvvReceived;

        inputTokenContract.forceApprove(aggregator, 0);

        emit SwappedToVVV(inputToken, inputAmount, vvvReceived, aggregator);
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
     * @notice Transfers mind ownership
     * @param newOwner The address that should receive ownership
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
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
        totalDeposited += amount;

        emit Deposit(contributor, amount, newTotal);
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
     * @dev Restricts calls to the deploying factory contract
     */
    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /**
     * @dev Restricts calls to the owner or the deploying factory contract
     */
    modifier onlyOwnerOrFactory() {
        address sender = msg.sender;
        if (sender != owner() && sender != factory) {
            revert UnauthorizedCaller();
        }
        _;
    }

    uint256[50] private _gap;
}
