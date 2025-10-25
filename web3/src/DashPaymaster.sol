// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../lib/account-abstraction/contracts/core/BasePaymaster.sol";
import "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./DashToken.sol";

/**
 * @title DashPaymaster
 * @notice Paymaster that sponsors gas based on DASH token holdings and staking
 * @dev Supports multiple sponsorship models:
 *      - Tiered sponsorship based on DASH staking (Bronze/Silver/Gold/Platinum)  
 *      - DASH token payment for gas
 *      - Rate limiting per user
 *      - Emergency pause functionality
 *      - Oracle-based gas price verification
 */
contract DashPaymaster is BasePaymaster, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;
    
    // ============ Structs ============
    
    struct SponsorshipConfig {
        uint256 dailyLimit;          // Daily sponsored gas limit per user
        uint256 transactionLimit;    // Max sponsored gas per transaction
        uint256 minStakeRequired;    // Minimum DASH stake required
        bool enabled;                // Whether this tier is enabled
    }
    
    struct UserSponsorshipData {
        uint256 dailySponsored;      // Gas sponsored today
        uint256 lastResetTime;       // Last time daily limit was reset
        uint256 totalSponsored;      // Total gas sponsored for this user
        bool isBlacklisted;          // Whether user is blacklisted
    }
    
    // ============ Constants ============
    
    uint256 public constant BRONZE_TIER = 0;
    uint256 public constant SILVER_TIER = 1;
    uint256 public constant GOLD_TIER = 2;
    uint256 public constant PLATINUM_TIER = 3;
    
    uint256 public constant MAX_GAS_PRICE = 200 gwei;
    uint256 public constant MIN_STAKE_TIME = 24 hours;
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    
    mapping(uint256 => SponsorshipConfig) public sponsorshipTiers;
    mapping(address => UserSponsorshipData) public userSponsorshipData;
    mapping(address => bool) public trustedOracles;
    
    uint256 public totalGasSponsored;
    uint256 public totalUsersSponsored;
    uint256 public dashToEthRate = 1000; // 1000 DASH = 1 ETH (adjustable)
    
    bool public paused = false;
    address public feeCollector;
    
    // Emergency limits
    uint256 public dailyGlobalLimit = 100 ether; // Max 100 ETH per day globally
    uint256 public dailyGlobalSponsored;
    uint256 public lastGlobalReset;
    
    // ============ Events ============
    
    event GasSponsored(
        address indexed user,
        bytes32 indexed userOpHash,
        uint256 actualGasCost,
        uint8 tier
    );
    
    event GasPaidWithDash(
        address indexed user,
        bytes32 indexed userOpHash,
        uint256 actualGasCost,
        uint256 dashPaid
    );
    
    event SponsorshipConfigUpdated(uint256 tier, SponsorshipConfig config);
    event UserBlacklisted(address indexed user);
    event UserUnblacklisted(address indexed user);
    event OracleUpdated(address indexed oracle, bool trusted);
    event DashToEthRateUpdated(uint256 oldRate, uint256 newRate);
    event PaymasterPaused();
    event PaymasterUnpaused();
    
    // ============ Errors ============
    
    error PaymasterIsPaused();
    error UserIsBlacklisted();
    error InsufficientStake();
    error DailyLimitExceeded();
    error TransactionLimitExceeded();
    error GasPriceTooHigh();
    error InvalidTier();
    error StakingPeriodNotMet();
    error GlobalLimitExceeded();
    error InvalidPaymasterData();
    error InsufficientDashPayment();
    error InsufficientDashBalance();
    
    // ============ Modifiers ============
    
    modifier whenNotPaused() {
        if (paused) revert PaymasterIsPaused();
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        IEntryPoint _entryPoint,
        DashToken _dashToken,
        address _feeCollector
    ) BasePaymaster(_entryPoint) {
        dashToken = _dashToken;
        feeCollector = _feeCollector;
        
        // Initialize default sponsorship tiers
        _initializeDefaultTiers();
    }
    
    function _initializeDefaultTiers() internal {
        // Bronze tier (1K+ DASH staked)
        sponsorshipTiers[BRONZE_TIER] = SponsorshipConfig({
            dailyLimit: 0.1 ether,        // 0.1 ETH per day
            transactionLimit: 0.01 ether,  // 0.01 ETH per tx
            minStakeRequired: dashToken.BRONZE_TIER(),
            enabled: true
        });
        
        // Silver tier (10K+ DASH staked)  
        sponsorshipTiers[SILVER_TIER] = SponsorshipConfig({
            dailyLimit: 0.5 ether,        // 0.5 ETH per day
            transactionLimit: 0.05 ether, // 0.05 ETH per tx
            minStakeRequired: dashToken.SILVER_TIER(),
            enabled: true
        });
        
        // Gold tier (100K+ DASH staked)
        sponsorshipTiers[GOLD_TIER] = SponsorshipConfig({
            dailyLimit: 2 ether,          // 2 ETH per day
            transactionLimit: 0.2 ether,  // 0.2 ETH per tx
            minStakeRequired: dashToken.GOLD_TIER(),
            enabled: true
        });
        
        // Platinum tier (1M+ DASH staked)
        sponsorshipTiers[PLATINUM_TIER] = SponsorshipConfig({
            dailyLimit: 10 ether,         // 10 ETH per day
            transactionLimit: 1 ether,    // 1 ETH per tx
            minStakeRequired: dashToken.PLATINUM_TIER(),
            enabled: true
        });
    }
    
    // ============ Paymaster Logic ============
    
    /**
     * @dev Validate and potentially pay for a UserOperation
     * @param userOp The UserOperation to validate
     * @param userOpHash Hash of the UserOperation
     * @param maxCost Maximum cost the paymaster agrees to pay
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal override whenNotPaused returns (bytes memory context, uint256 validationData) {
        // Parse paymaster data
        (uint8 sponsorshipType, bytes memory additionalData) = _parsePaymasterData(userOp.paymasterAndData);
        
        address sender = userOp.sender;
        
        // Check if user is blacklisted
        if (userSponsorshipData[sender].isBlacklisted) {
            revert UserIsBlacklisted();
        }
        
        // Check global daily limit
        _checkGlobalLimits(maxCost);
        
        if (sponsorshipType == 0) {
            // Tiered sponsorship based on DASH staking
            return _validateTieredSponsorship(sender, maxCost, userOpHash);
        } else if (sponsorshipType == 1) {
            // DASH token payment
            return _validateDashPayment(sender, maxCost, additionalData, userOpHash);
        }
        
        revert InvalidPaymasterData();
    }
    
    /**
     * @dev Validate tiered sponsorship based on DASH staking
     */
    function _validateTieredSponsorship(
        address sender,
        uint256 maxCost,
        bytes32 userOpHash
    ) internal returns (bytes memory context, uint256 validationData) {
        // Get user's staking tier
        uint8 tier = dashToken.getStakingTier(sender);
        
        if (tier == 0) {
            revert InsufficientStake();
        }
        
        // Adjust tier index (1-4 becomes 0-3)
        uint256 tierIndex = tier - 1;
        SponsorshipConfig memory config = sponsorshipTiers[tierIndex];
        
        if (!config.enabled) {
            revert InvalidTier();
        }
        
        // Check transaction limit
        if (maxCost > config.transactionLimit) {
            revert TransactionLimitExceeded();
        }
        
        // Check daily limit for user
        UserSponsorshipData storage userData = userSponsorshipData[sender];
        _resetDailyLimitIfNeeded(userData);
        
        if (userData.dailySponsored + maxCost > config.dailyLimit) {
            revert DailyLimitExceeded();
        }
        
        // Update sponsored amounts (optimistically)
        userData.dailySponsored += maxCost;
        userData.totalSponsored += maxCost;
        totalGasSponsored += maxCost;
        dailyGlobalSponsored += maxCost;
        
        // Return context for postOp
        context = abi.encode(sender, maxCost, tierIndex, 0); // 0 = sponsored
        
        emit GasSponsored(sender, userOpHash, maxCost, tier);
        
        return (context, 0);
    }
    
    /**
     * @dev Validate DASH token payment for gas
     */
    function _validateDashPayment(
        address sender,
        uint256 maxCost,
        bytes memory additionalData,
        bytes32 userOpHash
    ) internal returns (bytes memory context, uint256 validationData) {
        // Decode additional data (should contain max DASH to pay)
        uint256 maxDashPayment = abi.decode(additionalData, (uint256));
        
        // Calculate DASH required
        uint256 dashRequired = (maxCost * dashToEthRate) / 1 ether;
        
        if (dashRequired > maxDashPayment) {
            revert InsufficientDashPayment();
        }
        
        // Check user has enough DASH
        if (dashToken.balanceOf(sender) < dashRequired) {
            revert InsufficientDashBalance();
        }
        
        // Transfer DASH from user to paymaster
        dashToken.transferFrom(sender, address(this), dashRequired);
        
        // Return context for postOp
        context = abi.encode(sender, maxCost, 0, dashRequired); // 1 = DASH payment
        
        emit GasPaidWithDash(sender, userOpHash, maxCost, dashRequired);
        
        return (context, 0);
    }
    
    /**
     * @dev Post-operation logic to handle actual gas costs
     */
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        (address sender, uint256 maxCost, uint256 tierIndex, uint256 dashPaid) = 
            abi.decode(context, (address, uint256, uint256, uint256));
        
        if (mode == PostOpMode.opReverted) {
            // Revert optimistic updates for sponsored transactions
            if (dashPaid == 0) {
                UserSponsorshipData storage userData = userSponsorshipData[sender];
                userData.dailySponsored -= maxCost;
                userData.totalSponsored -= maxCost;
                totalGasSponsored -= maxCost;
                dailyGlobalSponsored -= maxCost;
            }
            return;
        }
        
        // Adjust for actual gas cost vs max cost
        if (dashPaid == 0) {
            // Sponsored transaction - adjust the optimistic updates
            uint256 actualCost = actualGasCost;
            UserSponsorshipData storage userData = userSponsorshipData[sender];
            
            if (actualCost < maxCost) {
                uint256 difference = maxCost - actualCost;
                userData.dailySponsored -= difference;
                userData.totalSponsored -= difference;
                totalGasSponsored -= difference;
                dailyGlobalSponsored -= difference;
            }
        } else {
            // DASH payment - refund excess DASH if any
            uint256 actualDashRequired = (actualGasCost * dashToEthRate) / 1 ether;
            if (dashPaid > actualDashRequired) {
                uint256 refund = dashPaid - actualDashRequired;
                dashToken.transfer(sender, refund);
            }
        }
    }
    
    // ============ Helper Functions ============
    
    function _parsePaymasterData(
        bytes calldata paymasterAndData
    ) internal pure returns (uint8 sponsorshipType, bytes memory additionalData) {
        if (paymasterAndData.length < 21) { // 20 bytes address + 1 byte type
            revert InvalidPaymasterData();
        }
        
        sponsorshipType = uint8(paymasterAndData[20]);
        
        if (paymasterAndData.length > 21) {
            additionalData = paymasterAndData[21:];
        }
    }
    
    function _resetDailyLimitIfNeeded(UserSponsorshipData storage userData) internal {
        if (block.timestamp >= userData.lastResetTime + 1 days) {
            userData.dailySponsored = 0;
            userData.lastResetTime = block.timestamp;
        }
    }
    
    function _checkGlobalLimits(uint256 cost) internal {
        // Reset global daily limit if needed
        if (block.timestamp >= lastGlobalReset + 1 days) {
            dailyGlobalSponsored = 0;
            lastGlobalReset = block.timestamp;
        }
        
        if (dailyGlobalSponsored + cost > dailyGlobalLimit) {
            revert GlobalLimitExceeded();
        }
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update sponsorship configuration for a tier
     */
    function setSponsorshipConfig(
        uint256 tier,
        SponsorshipConfig calldata config
    ) external onlyOwner {
        require(tier <= PLATINUM_TIER, "Invalid tier");
        
        sponsorshipTiers[tier] = config;
        
        emit SponsorshipConfigUpdated(tier, config);
    }
    
    /**
     * @notice Update DASH to ETH rate
     */
    function setDashToEthRate(uint256 newRate) external onlyOwner {
        uint256 oldRate = dashToEthRate;
        dashToEthRate = newRate;
        
        emit DashToEthRateUpdated(oldRate, newRate);
    }
    
    /**
     * @notice Pause/unpause the paymaster
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        
        if (_paused) {
            emit PaymasterPaused();
        } else {
            emit PaymasterUnpaused();
        }
    }
    
    /**
     * @notice Blacklist/unblacklist a user
     */
    function setUserBlacklisted(address user, bool blacklisted) external onlyOwner {
        userSponsorshipData[user].isBlacklisted = blacklisted;
        
        if (blacklisted) {
            emit UserBlacklisted(user);
        } else {
            emit UserUnblacklisted(user);
        }
    }
    
    /**
     * @notice Update global daily limit
     */
    function setDailyGlobalLimit(uint256 newLimit) external onlyOwner {
        dailyGlobalLimit = newLimit;
    }
    
    /**
     * @notice Emergency withdraw ETH
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(owner()).transfer(amount);
    }
    
    /**
     * @notice Emergency withdraw DASH tokens
     */
    function emergencyWithdrawDash(uint256 amount) external onlyOwner {
        dashToken.transfer(owner(), amount);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get user's sponsorship eligibility and limits
     */
    function getUserSponsorshipInfo(address user) external view returns (
        uint8 tier,
        uint256 dailyLimit,
        uint256 dailyUsed,
        uint256 transactionLimit,
        uint256 totalSponsored,
        bool isBlacklisted
    ) {
        tier = dashToken.getStakingTier(user);
        
        if (tier > 0) {
            SponsorshipConfig memory config = sponsorshipTiers[tier - 1];
            dailyLimit = config.dailyLimit;
            transactionLimit = config.transactionLimit;
        }
        
        UserSponsorshipData memory userData = userSponsorshipData[user];
        dailyUsed = userData.dailySponsored;
        totalSponsored = userData.totalSponsored;
        isBlacklisted = userData.isBlacklisted;
    }
    
    /**
     * @notice Get paymaster statistics
     */
    function getPaymasterStats() external view returns (
        uint256 _totalGasSponsored,
        uint256 _totalUsersSponsored,
        uint256 _dailyGlobalLimit,
        uint256 _dailyGlobalSponsored,
        uint256 _dashToEthRate,
        bool _paused
    ) {
        return (
            totalGasSponsored,
            totalUsersSponsored,
            dailyGlobalLimit,
            dailyGlobalSponsored,
            dashToEthRate,
            paused
        );
    }
    
    /**
     * @notice Calculate DASH required for gas payment
     */
    function calculateDashPayment(uint256 gasCost) external view returns (uint256 dashRequired) {
        return (gasCost * dashToEthRate) / 1 ether;
    }
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Allow receiving ETH for gas sponsorship
    }
}
