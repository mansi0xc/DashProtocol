// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./DashToken.sol";

/**
 * @title SimpleLiquidityPool
 * @notice UniswapV2-style constant product AMM for DASH/ETH trading
 * @dev Implements x * y = k formula with the following features:
 *      - 0.3% trading fee with DASH staking discounts
 *      - TWAP oracle for price feeds
 *      - LP token rewards and incentives
 *      - MEV protection and slippage controls
 *      - Emergency pause and admin functions
 */
contract SimpleLiquidityPool is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // ============ Constants ============
    
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant BASE_FEE = 30; // 0.3%
    uint256 public constant TWAP_PERIOD = 30 minutes;
    
    // ============ Immutable State ============
    
    DashToken public immutable dashToken;
    IERC20 public immutable tokenA; // DASH
    IERC20 public immutable tokenB; // WETH or ETH
    
    // ============ Pool State ============
    
    struct PoolInfo {
        uint256 reserveA;           // DASH reserve
        uint256 reserveB;           // ETH reserve  
        uint256 totalFees;          // Accumulated fees
        uint256 lastUpdateTime;     // Last update timestamp
        uint256 kLast;              // Last K value for fee calculation
    }
    
    struct TWAPData {
        uint256 price0Average;      // DASH/ETH price
        uint256 price1Average;      // ETH/DASH price
        uint256 lastUpdateTime;     // Last TWAP update
        uint256 lastBlockTimestamp; // Last block timestamp
    }
    
    PoolInfo public poolInfo;
    TWAPData public twapData;
    
    // Fee collection and distribution
    uint256 public protocolFeeShare = 1600; // 16% of trading fees (0.048% of trade)
    address public feeCollector;
    mapping(address => uint256) public userFeeDiscounts;
    
    // LP rewards and incentives
    mapping(address => uint256) public lastRewardTime;
    mapping(address => uint256) public pendingRewards;
    uint256 public rewardRate = 100 * 1e18; // 100 DASH per day base rate
    uint256 public totalRewardsDistributed;
    
    // Security and limits
    uint256 public maxSingleSwap = 100 ether; // Max ETH per swap
    uint256 public maxDailyVolume = 1000 ether; // Max ETH volume per day
    uint256 public dailyVolume;
    uint256 public lastVolumeReset;
    
    // ============ Events ============
    
    event LiquidityAdded(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        uint256 timestamp
    );
    
    event LiquidityRemoved(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        uint256 timestamp
    );
    
    event Swap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 timestamp
    );
    
    event RewardsDistributed(address indexed user, uint256 amount);
    event FeesCollected(uint256 amount, address indexed collector);
    event TWAPUpdated(uint256 price0, uint256 price1, uint256 timestamp);
    
    // ============ Errors ============
    
    error InsufficientLiquidity();
    error InsufficientAmount();
    error InsufficientOutputAmount();
    error ExcessiveSlippage();
    error SwapLimitExceeded();
    error DailyVolumeExceeded();
    error InvalidToken();
    error ZeroAddress();
    error InvalidFeeShare();
    
    // ============ Constructor ============
    
    constructor(
        DashToken _dashToken,
        IERC20 _tokenB, 
        address _feeCollector,
        address initialOwner
    ) 
        ERC20("DASH-ETH LP", "DASH-ETH-LP") 
        Ownable(initialOwner)
    {
        dashToken = _dashToken;
        tokenA = IERC20(address(_dashToken));
        tokenB = _tokenB;
        feeCollector = _feeCollector;
        
        // Initialize TWAP
        twapData.lastUpdateTime = block.timestamp;
        twapData.lastBlockTimestamp = block.timestamp;
        
        // Initialize daily volume tracking
        lastVolumeReset = block.timestamp;
    }
    
    // ============ Liquidity Functions ============
    
    /**
     * @notice Add liquidity to the pool
     * @param amountADesired Desired amount of DASH to add
     * @param amountBDesired Desired amount of ETH to add
     * @param amountAMin Minimum DASH amount (slippage protection)
     * @param amountBMin Minimum ETH amount (slippage protection)
     * @param to Address to receive LP tokens
     * @param deadline Transaction deadline
     */
    function addLiquidity(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 liquidity) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(to != address(0), "Invalid recipient");
        
        // Handle ETH deposits
        if (address(tokenB) == address(0)) {
            require(msg.value == amountBDesired, "ETH amount mismatch");
        }
        
        (uint256 amountA, uint256 amountB) = _calculateOptimalAmounts(
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        
        // Transfer tokens
        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        if (address(tokenB) != address(0)) {
            tokenB.safeTransferFrom(msg.sender, address(this), amountB);
        }
        
        // Mint LP tokens
        liquidity = _mintLiquidity(to, amountA, amountB);
        
        // Update pool state
        _updateReserves();
        _updateTWAP();
        
        // Update rewards
        _updateRewards(to);
        
        emit LiquidityAdded(msg.sender, amountA, amountB, liquidity, block.timestamp);
    }
    
    /**
     * @notice Remove liquidity from the pool
     * @param liquidity Amount of LP tokens to burn
     * @param amountAMin Minimum DASH to receive
     * @param amountBMin Minimum ETH to receive  
     * @param to Address to receive tokens
     * @param deadline Transaction deadline
     */
    function removeLiquidity(
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external whenNotPaused nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(to != address(0), "Invalid recipient");
        
        (amountA, amountB) = _burnLiquidity(msg.sender, liquidity, to);
        
        require(amountA >= amountAMin, "Insufficient DASH amount");
        require(amountB >= amountBMin, "Insufficient ETH amount");
        
        // Update pool state
        _updateReserves();
        _updateTWAP();
        
        // Update rewards
        _updateRewards(msg.sender);
        
        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidity, block.timestamp);
    }
    
    // ============ Swap Functions ============
    
    /**
     * @notice Swap exact tokens for tokens
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param tokenIn Input token address
     * @param to Address to receive output tokens
     * @param deadline Transaction deadline
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(to != address(0), "Invalid recipient");
        
        // Validate token and handle ETH
        bool isTokenAInput = _validateSwapToken(tokenIn, amountIn);
        
        // Check limits
        _checkSwapLimits(amountIn, isTokenAInput);
        
        // Calculate output amount with fees
        amountOut = _getAmountOut(amountIn, isTokenAInput, msg.sender);
        require(amountOut >= amountOutMin, "Insufficient output amount");
        
        // Execute swap
        _executeSwap(amountIn, amountOut, isTokenAInput, to);
        
        // Update state
        _updateReserves();
        _updateTWAP();
        _updateDailyVolume(amountIn, isTokenAInput);
        
        emit Swap(
            msg.sender,
            tokenIn,
            isTokenAInput ? address(tokenB) : address(tokenA),
            amountIn,
            amountOut,
            _calculateFee(amountIn, msg.sender),
            block.timestamp
        );
    }
    
    /**
     * @notice Swap tokens for exact tokens
     * @param amountOut Exact amount of output tokens desired
     * @param amountInMax Maximum input amount willing to pay
     * @param tokenIn Input token address
     * @param to Address to receive output tokens
     * @param deadline Transaction deadline
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address tokenIn,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 amountIn) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(to != address(0), "Invalid recipient");
        
        bool isTokenAInput = _validateSwapToken(tokenIn, 0);
        
        // Calculate required input amount
        amountIn = _getAmountIn(amountOut, isTokenAInput, msg.sender);
        require(amountIn <= amountInMax, "Excessive input amount");
        
        // Check limits
        _checkSwapLimits(amountIn, isTokenAInput);
        
        // Handle ETH input validation
        if (!isTokenAInput && address(tokenB) == address(0)) {
            require(msg.value >= amountIn, "Insufficient ETH sent");
            // Refund excess ETH
            if (msg.value > amountIn) {
                payable(msg.sender).transfer(msg.value - amountIn);
            }
        }
        
        // Execute swap
        _executeSwap(amountIn, amountOut, isTokenAInput, to);
        
        // Update state
        _updateReserves();
        _updateTWAP();
        _updateDailyVolume(amountIn, isTokenAInput);
        
        emit Swap(
            msg.sender,
            tokenIn,
            isTokenAInput ? address(tokenB) : address(tokenA),
            amountIn,
            amountOut,
            _calculateFee(amountIn, msg.sender),
            block.timestamp
        );
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get current pool reserves
     */
    function getReserves() external view returns (uint256 reserveA, uint256 reserveB, uint256 blockTimestamp) {
        reserveA = poolInfo.reserveA;
        reserveB = poolInfo.reserveB;
        blockTimestamp = poolInfo.lastUpdateTime;
    }
    
    /**
     * @notice Get amount out for a given input
     * @param amountIn Input amount
     * @param isTokenAInput Whether input token is tokenA (DASH)
     * @param trader Trader address for fee calculation
     */
    function getAmountOut(uint256 amountIn, bool isTokenAInput, address trader) 
        external 
        view 
        returns (uint256 amountOut) 
    {
        return _getAmountOut(amountIn, isTokenAInput, trader);
    }
    
    /**
     * @notice Get amount in for a given output
     * @param amountOut Desired output amount
     * @param isTokenAInput Whether input token is tokenA (DASH)
     * @param trader Trader address for fee calculation
     */
    function getAmountIn(uint256 amountOut, bool isTokenAInput, address trader)
        external
        view
        returns (uint256 amountIn)
    {
        return _getAmountIn(amountOut, isTokenAInput, trader);
    }
    
    /**
     * @notice Get current TWAP prices
     */
    function getTWAPPrice() external view returns (uint256 price0, uint256 price1) {
        if (poolInfo.reserveA == 0 || poolInfo.reserveB == 0) {
            return (0, 0);
        }
        
        price0 = twapData.price0Average;
        price1 = twapData.price1Average;
    }
    
    /**
     * @notice Get user's pending rewards
     */
    function getPendingRewards(address user) external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastRewardTime[user];
        uint256 userLP = balanceOf(user);
        uint256 totalLP = totalSupply();
        
        if (totalLP == 0) return pendingRewards[user];
        
        uint256 newRewards = (timeElapsed * rewardRate * userLP) / (86400 * totalLP);
        return pendingRewards[user] + newRewards;
    }
    
    /**
     * @notice Get pool statistics
     */
    function getPoolStats() external view returns (
        uint256 _totalLiquidity,
        uint256 _totalVolume24h,
        uint256 _totalFees,
        uint256 _apy,
        uint256 _utilizationRate
    ) {
        _totalLiquidity = totalSupply();
        _totalVolume24h = dailyVolume;
        _totalFees = poolInfo.totalFees;
        
        // Calculate APY based on fees and rewards
        if (_totalLiquidity > 0) {
            uint256 dailyFees = (_totalFees * 86400) / (block.timestamp - poolInfo.lastUpdateTime + 1);
            uint256 dailyRewards = rewardRate;
            _apy = ((dailyFees + dailyRewards) * 365 * 100) / _totalLiquidity;
        }
        
        // Utilization rate (daily volume / total liquidity)
        if (_totalLiquidity > 0) {
            _utilizationRate = (_totalVolume24h * 100) / _totalLiquidity;
        }
    }
    
    // ============ Internal Functions ============
    
    function _calculateOptimalAmounts(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        if (poolInfo.reserveA == 0 && poolInfo.reserveB == 0) {
            // First liquidity
            return (amountADesired, amountBDesired);
        }
        
        uint256 amountBOptimal = (amountADesired * poolInfo.reserveB) / poolInfo.reserveA;
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "Insufficient B amount");
            return (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = (amountBDesired * poolInfo.reserveA) / poolInfo.reserveB;
            require(amountAOptimal <= amountADesired && amountAOptimal >= amountAMin, "Insufficient A amount");
            return (amountAOptimal, amountBDesired);
        }
    }
    
    function _mintLiquidity(address to, uint256 amountA, uint256 amountB) internal returns (uint256 liquidity) {
        uint256 totalLiquidity = totalSupply();
        
        if (totalLiquidity == 0) {
            liquidity = Math.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY); // Lock minimum liquidity
        } else {
            liquidity = Math.min(
                (amountA * totalLiquidity) / poolInfo.reserveA,
                (amountB * totalLiquidity) / poolInfo.reserveB
            );
        }
        
        require(liquidity > 0, "Insufficient liquidity minted");
        _mint(to, liquidity);
    }
    
    function _burnLiquidity(address from, uint256 liquidity, address to) 
        internal 
        returns (uint256 amountA, uint256 amountB) 
    {
        uint256 totalLiquidity = totalSupply();
        
        amountA = (liquidity * poolInfo.reserveA) / totalLiquidity;
        amountB = (liquidity * poolInfo.reserveB) / totalLiquidity;
        
        require(amountA > 0 && amountB > 0, "Insufficient liquidity burned");
        
        _burn(from, liquidity);
        
        // Transfer tokens
        tokenA.safeTransfer(to, amountA);
        if (address(tokenB) == address(0)) {
            payable(to).transfer(amountB);
        } else {
            tokenB.safeTransfer(to, amountB);
        }
    }
    
    function _getAmountOut(uint256 amountIn, bool isTokenAInput, address trader) 
        internal 
        view 
        returns (uint256 amountOut) 
    {
        require(amountIn > 0, "Insufficient input amount");
        
        uint256 reserveIn = isTokenAInput ? poolInfo.reserveA : poolInfo.reserveB;
        uint256 reserveOut = isTokenAInput ? poolInfo.reserveB : poolInfo.reserveA;
        
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        // Calculate fee with potential discount
        uint256 fee = _calculateFee(amountIn, trader);
        uint256 amountInWithFee = amountIn - fee;
        
        // Constant product formula: (x + Δx)(y - Δy) = xy
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithFee;
        
        amountOut = numerator / denominator;
    }
    
    function _getAmountIn(uint256 amountOut, bool isTokenAInput, address trader)
        internal
        view
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "Insufficient output amount");
        
        uint256 reserveIn = isTokenAInput ? poolInfo.reserveA : poolInfo.reserveB;
        uint256 reserveOut = isTokenAInput ? poolInfo.reserveB : poolInfo.reserveA;
        
        require(reserveIn > 0 && reserveOut > amountOut, "Insufficient liquidity");
        
        // Calculate required input before fees
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        uint256 amountInBeforeFee = numerator / denominator + 1;
        
        // Account for fees
        uint256 feeRate = _getFeeRate(trader);
        amountIn = (amountInBeforeFee * FEE_DENOMINATOR) / (FEE_DENOMINATOR - feeRate);
    }
    
    function _calculateFee(uint256 amount, address trader) internal view returns (uint256) {
        uint256 feeRate = _getFeeRate(trader);
        return (amount * feeRate) / FEE_DENOMINATOR;
    }
    
    function _getFeeRate(address trader) internal view returns (uint256) {
        uint256 discount = dashToken.getFeeDiscount(trader);
        uint256 effectiveFee = BASE_FEE;
        
        if (discount > 0) {
            effectiveFee = (BASE_FEE * (FEE_DENOMINATOR - discount)) / FEE_DENOMINATOR;
        }
        
        return effectiveFee;
    }
    
    function _validateSwapToken(address tokenIn, uint256 amountIn) internal view returns (bool isTokenAInput) {
        if (tokenIn == address(tokenA)) {
            isTokenAInput = true;
        } else if (tokenIn == address(tokenB) || (tokenIn == address(0) && address(tokenB) == address(0))) {
            isTokenAInput = false;
            if (address(tokenB) == address(0)) {
                require(msg.value >= amountIn, "Insufficient ETH sent");
            }
        } else {
            revert InvalidToken();
        }
    }
    
    function _executeSwap(uint256 amountIn, uint256 amountOut, bool isTokenAInput, address to) internal {
        if (isTokenAInput) {
            // DASH -> ETH swap
            tokenA.safeTransferFrom(msg.sender, address(this), amountIn);
            
            if (address(tokenB) == address(0)) {
                payable(to).transfer(amountOut);
            } else {
                tokenB.safeTransfer(to, amountOut);
            }
        } else {
            // ETH -> DASH swap
            if (address(tokenB) == address(0)) {
                // ETH already received via msg.value
                uint256 excess = msg.value - amountIn;
                if (excess > 0) {
                    payable(msg.sender).transfer(excess);
                }
            } else {
                tokenB.safeTransferFrom(msg.sender, address(this), amountIn);
            }
            
            tokenA.safeTransfer(to, amountOut);
        }
    }
    
    function _checkSwapLimits(uint256 amountIn, bool isTokenAInput) internal view {
        // Convert to ETH value for limit checking
        uint256 ethValue = isTokenAInput 
            ? (amountIn * poolInfo.reserveB) / poolInfo.reserveA
            : amountIn;
            
        require(ethValue <= maxSingleSwap, "Swap amount too large");
        require(dailyVolume + ethValue <= maxDailyVolume, "Daily volume exceeded");
    }
    
    function _updateReserves() internal {
        poolInfo.reserveA = tokenA.balanceOf(address(this));
        poolInfo.reserveB = address(tokenB) == address(0) 
            ? address(this).balance 
            : tokenB.balanceOf(address(this));
        poolInfo.lastUpdateTime = block.timestamp;
    }
    
    function _updateTWAP() internal {
        uint256 timeElapsed = block.timestamp - twapData.lastBlockTimestamp;
        
        if (timeElapsed > 0 && poolInfo.reserveA > 0 && poolInfo.reserveB > 0) {
            // Update TWAP prices
            uint256 price0 = (poolInfo.reserveB * PRECISION) / poolInfo.reserveA; // ETH per DASH
            uint256 price1 = (poolInfo.reserveA * PRECISION) / poolInfo.reserveB; // DASH per ETH
            
            // Simple moving average
            if (twapData.lastUpdateTime > 0) {
                uint256 weight = Math.min(timeElapsed, TWAP_PERIOD);
                uint256 totalWeight = weight + TWAP_PERIOD;
                
                twapData.price0Average = (twapData.price0Average * TWAP_PERIOD + price0 * weight) / totalWeight;
                twapData.price1Average = (twapData.price1Average * TWAP_PERIOD + price1 * weight) / totalWeight;
            } else {
                twapData.price0Average = price0;
                twapData.price1Average = price1;
            }
            
            twapData.lastUpdateTime = block.timestamp;
            twapData.lastBlockTimestamp = block.timestamp;
            
            emit TWAPUpdated(twapData.price0Average, twapData.price1Average, block.timestamp);
        }
    }
    
    function _updateRewards(address user) internal {
        if (balanceOf(user) > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime[user];
            uint256 userLP = balanceOf(user);
            uint256 totalLP = totalSupply();
            
            if (totalLP > 0) {
                uint256 newRewards = (timeElapsed * rewardRate * userLP) / (86400 * totalLP);
                pendingRewards[user] += newRewards;
            }
        }
        lastRewardTime[user] = block.timestamp;
    }
    
    function _updateDailyVolume(uint256 amountIn, bool isTokenAInput) internal {
        // Reset daily volume if needed
        if (block.timestamp >= lastVolumeReset + 1 days) {
            dailyVolume = 0;
            lastVolumeReset = block.timestamp;
        }
        
        // Add to daily volume (convert to ETH equivalent)
        uint256 ethValue = isTokenAInput 
            ? (amountIn * poolInfo.reserveB) / poolInfo.reserveA
            : amountIn;
            
        dailyVolume += ethValue;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Claim pending rewards
     */
    function claimRewards() external nonReentrant {
        _updateRewards(msg.sender);
        
        uint256 rewards = pendingRewards[msg.sender];
        require(rewards > 0, "No rewards to claim");
        
        pendingRewards[msg.sender] = 0;
        totalRewardsDistributed += rewards;
        
        // Mint DASH rewards (requires minter role)
        dashToken.mint(msg.sender, rewards);
        
        emit RewardsDistributed(msg.sender, rewards);
    }
    
    /**
     * @notice Collect protocol fees (admin only)
     */
    function collectFees() external onlyOwner {
        uint256 fees = poolInfo.totalFees;
        require(fees > 0, "No fees to collect");
        
        poolInfo.totalFees = 0;
        dashToken.mint(feeCollector, fees);
        
        emit FeesCollected(fees, feeCollector);
    }
    
    /**
     * @notice Set protocol fee share (admin only)
     */
    function setProtocolFeeShare(uint256 newFeeShare) external onlyOwner {
        require(newFeeShare <= 2500, "Fee share too high"); // Max 25%
        protocolFeeShare = newFeeShare;
    }
    
    /**
     * @notice Set reward rate (admin only)
     */
    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
    }
    
    /**
     * @notice Pause/unpause the pool (admin only)
     */
    function setPaused(bool paused) external onlyOwner {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    /**
     * @notice Update swap limits (admin only)
     */
    function updateLimits(uint256 newMaxSingleSwap, uint256 newMaxDailyVolume) external onlyOwner {
        maxSingleSwap = newMaxSingleSwap;
        maxDailyVolume = newMaxDailyVolume;
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency withdrawal (admin only)
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }
    
    // ============ Fallback ============
    
    receive() external payable {
        // Allow receiving ETH for ETH/DASH pool
        require(address(tokenB) == address(0), "Pool doesn't accept ETH");
    }
}
