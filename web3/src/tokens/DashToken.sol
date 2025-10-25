// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DashToken
 * @notice The native token of the Dash Protocol ecosystem
 * @dev ERC20 token with advanced features:
 *      - Mintable (controlled by owner/governance)
 *      - Burnable (for fee burn mechanism)
 *      - Permit (EIP-2612 for gasless approvals)
 *      - Votes (for governance)
 *      - Pausable (for emergency situations)
 *      - Fee discount mechanics based on staking tiers
 */
contract DashToken is 
    ERC20, 
    ERC20Burnable, 
    ERC20Permit, 
    ERC20Votes, 
    Ownable, 
    Pausable, 
    ReentrancyGuard 
{
    // ============ Constants ============
    
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18; // 1B tokens
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 10**18;    // 10B max supply
    
    // Staking tier thresholds for fee discounts
    uint256 public constant BRONZE_TIER = 1_000 * 10**18;      // 1K DASH
    uint256 public constant SILVER_TIER = 10_000 * 10**18;     // 10K DASH
    uint256 public constant GOLD_TIER = 100_000 * 10**18;      // 100K DASH
    uint256 public constant PLATINUM_TIER = 1_000_000 * 10**18; // 1M DASH
    
    // ============ State Variables ============
    
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakingTimestamp;
    mapping(address => bool) public minters; // Authorized minters
    
    uint256 public totalStaked;
    bool public stakingEnabled = true;
    uint256 public minimumStakingPeriod = 7 days;
    
    // Fee burn tracking
    uint256 public totalBurned;
    uint256 public burnRate = 200; // 2% (200/10000)
    
    // ============ Events ============
    
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event BurnRateUpdated(uint256 oldRate, uint256 newRate);
    event TokensBurned(uint256 amount, address indexed burner);
    event StakingStatusChanged(bool enabled);
    
    // ============ Errors ============
    
    error ExceedsMaxSupply();
    error NotAuthorizedMinter();
    error StakingDisabled();
    error InsufficientStakedBalance();
    error StakingPeriodNotMet();
    error InvalidBurnRate();
    error ZeroAmount();
    
    // ============ Constructor ============
    
    constructor(
        address initialOwner,
        address treasury
    ) 
        ERC20("Dash Protocol Token", "DASH") 
        ERC20Permit("Dash Protocol Token")
        Ownable(initialOwner)
    {
        _mint(treasury, INITIAL_SUPPLY);
        
        // Add initial owner as a minter
        minters[initialOwner] = true;
        emit MinterAdded(initialOwner);
    }
    
    // ============ Minting Functions ============
    
    /**
     * @notice Mint tokens to a specific address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotAuthorizedMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        
        _mint(to, amount);
    }
    
    /**
     * @notice Add a new authorized minter
     * @param minter The address to add as a minter
     */
    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
        emit MinterAdded(minter);
    }
    
    /**
     * @notice Remove an authorized minter
     * @param minter The address to remove as a minter
     */
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }
    
    // ============ Staking Functions ============
    
    /**
     * @notice Stake DASH tokens to earn fee discounts
     * @param amount The amount of tokens to stake
     */
    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (!stakingEnabled) revert StakingDisabled();
        if (amount == 0) revert ZeroAmount();
        
        _transfer(msg.sender, address(this), amount);
        
        stakedBalance[msg.sender] += amount;
        stakingTimestamp[msg.sender] = block.timestamp;
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, block.timestamp);
    }
    
    /**
     * @notice Unstake DASH tokens
     * @param amount The amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] < amount) revert InsufficientStakedBalance();
        if (block.timestamp < stakingTimestamp[msg.sender] + minimumStakingPeriod) {
            revert StakingPeriodNotMet();
        }
        
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        
        _transfer(address(this), msg.sender, amount);
        
        emit Unstaked(msg.sender, amount, block.timestamp);
    }
    
    /**
     * @notice Get the staking tier for an address
     * @param user The address to check
     * @return tier The staking tier (0 = no tier, 1 = bronze, 2 = silver, 3 = gold, 4 = platinum)
     */
    function getStakingTier(address user) external view returns (uint8 tier) {
        uint256 staked = stakedBalance[user];
        
        if (staked >= PLATINUM_TIER) return 4;
        if (staked >= GOLD_TIER) return 3;
        if (staked >= SILVER_TIER) return 2;
        if (staked >= BRONZE_TIER) return 1;
        return 0;
    }
    
    /**
     * @notice Get the fee discount percentage for an address
     * @param user The address to check
     * @return discount The discount percentage (in basis points, e.g., 500 = 5%)
     */
    function getFeeDiscount(address user) external view returns (uint256 discount) {
        uint256 staked = stakedBalance[user];
        
        if (staked >= PLATINUM_TIER) return 5000; // 50% discount
        if (staked >= GOLD_TIER) return 2500;     // 25% discount
        if (staked >= SILVER_TIER) return 1000;   // 10% discount
        if (staked >= BRONZE_TIER) return 500;    // 5% discount
        return 0; // No discount
    }
    
    // ============ Fee Burn Mechanism ============
    
    /**
     * @notice Burn tokens collected as fees
     * @param amount The amount of tokens to burn
     */
    function burnFees(uint256 amount) external {
        if (!minters[msg.sender]) revert NotAuthorizedMinter();
        if (amount == 0) revert ZeroAmount();
        
        totalBurned += amount;
        _burn(address(this), amount);
        
        emit TokensBurned(amount, msg.sender);
    }
    
    /**
     * @notice Update the burn rate for fees
     * @param newRate The new burn rate (in basis points)
     */
    function setBurnRate(uint256 newRate) external onlyOwner {
        if (newRate > 5000) revert InvalidBurnRate(); // Max 50%
        
        uint256 oldRate = burnRate;
        burnRate = newRate;
        
        emit BurnRateUpdated(oldRate, newRate);
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause all token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Enable or disable staking
     * @param enabled Whether staking should be enabled
     */
    function setStakingEnabled(bool enabled) external onlyOwner {
        stakingEnabled = enabled;
        emit StakingStatusChanged(enabled);
    }
    
    /**
     * @notice Set minimum staking period
     * @param period The new minimum staking period in seconds
     */
    function setMinimumStakingPeriod(uint256 period) external onlyOwner {
        minimumStakingPeriod = period;
    }
    
    // Note: Snapshot functionality removed in OpenZeppelin v5
    // Can be implemented separately if needed for governance/airdrops
    
    // ============ View Functions ============
    
    /**
     * @notice Get comprehensive token information
     */
    function getTokenInfo() external view returns (
        uint256 _totalSupply,
        uint256 _maxSupply,
        uint256 _totalStaked,
        uint256 _totalBurned,
        uint256 _burnRate,
        bool _stakingEnabled
    ) {
        return (
            totalSupply(),
            MAX_SUPPLY,
            totalStaked,
            totalBurned,
            burnRate,
            stakingEnabled
        );
    }
    
    // ============ Override Functions ============
    
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) whenNotPaused {
        super._update(from, to, value);
    }
    
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
