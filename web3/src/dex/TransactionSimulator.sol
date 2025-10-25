// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../tokens/DashToken.sol";
import "./SimpleLiquidityPool.sol";
import "./DashSmartRouter.sol";

/**
 * @title TransactionSimulator
 * @notice Advanced transaction simulation and preview system for DEX operations
 * @dev Features:
 *      - Gas estimation for complex transactions
 *      - Price impact calculations
 *      - Multi-hop route simulation
 *      - MEV attack detection
 *      - Slippage tolerance optimization
 */
contract TransactionSimulator is Ownable {
    using SafeERC20 for IERC20;
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    SimpleLiquidityPool public immutable dashPool;
    DashSmartRouter public immutable smartRouter;
    
    // Simulation parameters
    uint256 public constant MAX_SIMULATION_STEPS = 10;
    uint256 public constant PRICE_IMPACT_THRESHOLD = 500; // 5%
    uint256 public constant MEV_THRESHOLD = 100; // 1%
    
    // ============ Structs ============
    
    struct SimulationResult {
        uint256 outputAmount;           // Expected output
        uint256 priceImpact;            // Price impact in bps
        uint256 gasEstimate;            // Gas cost estimate
        uint256 optimalSlippage;        // Recommended slippage
        bool mevRisk;                   // MEV attack risk detected
        bytes routeData;                // Optimal route data
        string[] warnings;              // Any warnings or issues
    }
    
    struct LiquiditySimulation {
        uint256 newReserveA;            // Projected reserve A
        uint256 newReserveB;            // Projected reserve B
        uint256 newPrice;               // New pool price
        uint256 lpTokensIssued;         // LP tokens that would be issued
        uint256 impermanentLoss;        // IL estimate
    }
    
    struct MarketConditions {
        uint256 currentGasPrice;        // Current gas price
        uint256 networkCongestion;      // Network congestion level
        uint256 volatility;             // Price volatility metric
        uint256 liquidityDepth;         // Available liquidity
    }
    
    // ============ Events ============
    
    event SimulationCompleted(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 estimatedOut,
        uint256 priceImpact
    );
    
    event MEVDetected(
        address indexed user,
        bytes32 txHash,
        uint256 riskLevel
    );
    
    // ============ Constructor ============
    
    constructor(
        DashToken _dashToken,
        SimpleLiquidityPool _dashPool,
        DashSmartRouter _smartRouter,
        address initialOwner
    ) Ownable(initialOwner) {
        dashToken = _dashToken;
        dashPool = _dashPool;
        smartRouter = _smartRouter;
    }
    
    // ============ Simulation Functions ============
    
    /**
     * @notice Simulate a swap transaction with detailed analysis
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount to swap
     * @param user User address (for fee calculations)
     * @return result Detailed simulation results
     */
    function simulateSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address user
    ) external returns (SimulationResult memory result) {
        require(amountIn > 0, "Invalid amount");
        
        // Get current market conditions
        MarketConditions memory market = _getMarketConditions();
        
        // Simulate the swap
        result.outputAmount = _simulateSwapExecution(tokenIn, tokenOut, amountIn, user);
        
        // Calculate price impact
        result.priceImpact = _calculatePriceImpact(tokenIn, tokenOut, amountIn);
        
        // Estimate gas costs
        result.gasEstimate = _estimateGasCost(tokenIn, tokenOut, amountIn, market.currentGasPrice);
        
        // Calculate optimal slippage
        result.optimalSlippage = _calculateOptimalSlippage(result.priceImpact, market.volatility);
        
        // Check MEV risk
        result.mevRisk = _detectMEVRisk(tokenIn, tokenOut, amountIn, result.priceImpact);
        
        // Generate route data
        result.routeData = _generateOptimalRoute(tokenIn, tokenOut, amountIn);
        
        // Generate warnings
        result.warnings = _generateWarnings(result, market);
        
        emit SimulationCompleted(user, tokenIn, tokenOut, amountIn, result.outputAmount, result.priceImpact);
    }
    
    /**
     * @notice Simulate liquidity addition with impermanent loss analysis
     * @param amountA Amount of token A to add
     * @param amountB Amount of token B to add
     * @return simulation Liquidity simulation results
     */
    function simulateLiquidityAddition(
        uint256 amountA,
        uint256 amountB
    ) external view returns (LiquiditySimulation memory simulation) {
        (uint256 reserveA, uint256 reserveB,) = dashPool.getReserves();
        
        // Calculate optimal amounts
        uint256 optimalAmountA = amountA;
        uint256 optimalAmountB = amountB;
        
        if (reserveA > 0 && reserveB > 0) {
            uint256 amountBOptimal = (amountA * reserveB) / reserveA;
            if (amountBOptimal <= amountB) {
                optimalAmountB = amountBOptimal;
            } else {
                optimalAmountA = (amountB * reserveA) / reserveB;
            }
        }
        
        // Project new reserves
        simulation.newReserveA = reserveA + optimalAmountA;
        simulation.newReserveB = reserveB + optimalAmountB;
        
        // Calculate new price
        if (simulation.newReserveA > 0) {
            simulation.newPrice = (simulation.newReserveB * 1e18) / simulation.newReserveA;
        }
        
        // Calculate LP tokens
        uint256 totalSupply = dashPool.totalSupply();
        if (totalSupply == 0) {
            simulation.lpTokensIssued = _sqrt(optimalAmountA * optimalAmountB) - 1000;
        } else {
            simulation.lpTokensIssued = _min(
                (optimalAmountA * totalSupply) / reserveA,
                (optimalAmountB * totalSupply) / reserveB
            );
        }
        
        // Estimate impermanent loss (simplified)
        simulation.impermanentLoss = _calculateImpermanentLoss(
            reserveA,
            reserveB,
            simulation.newReserveA,
            simulation.newReserveB
        );
    }
    
    /**
     * @notice Simulate multi-hop swap route
     * @param path Array of token addresses for the route
     * @param amountIn Input amount
     * @param user User address
     * @return amounts Array of amounts for each hop
     * @return totalGas Total gas estimate
     */
    function simulateMultiHop(
        address[] calldata path,
        uint256 amountIn,
        address user
    ) external view returns (uint256[] memory amounts, uint256 totalGas) {
        require(path.length >= 2, "Invalid path");
        require(path.length <= MAX_SIMULATION_STEPS, "Path too long");
        
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        
        for (uint256 i = 0; i < path.length - 1; i++) {
            // Simulate each hop
            amounts[i + 1] = _simulateSwapExecution(
                path[i],
                path[i + 1],
                amounts[i],
                user
            );
            
            // Add gas estimate for this hop
            MarketConditions memory market = _getMarketConditions();
            totalGas += _estimateGasCost(path[i], path[i + 1], amounts[i], market.currentGasPrice);
        }
    }
    
    /**
     * @notice Get current market conditions
     */
    function getMarketConditions() external view returns (MarketConditions memory) {
        return _getMarketConditions();
    }
    
    /**
     * @notice Batch simulate multiple swaps
     * @param tokenIns Array of input tokens
     * @param tokenOuts Array of output tokens
     * @param amountsIn Array of input amounts
     * @param user User address
     * @return results Array of simulation results
     */
    function batchSimulate(
        address[] calldata tokenIns,
        address[] calldata tokenOuts,
        uint256[] calldata amountsIn,
        address user
    ) external returns (SimulationResult[] memory results) {
        require(
            tokenIns.length == tokenOuts.length && 
            tokenOuts.length == amountsIn.length,
            "Array length mismatch"
        );
        
        results = new SimulationResult[](tokenIns.length);
        
        for (uint256 i = 0; i < tokenIns.length; i++) {
            results[i] = this.simulateSwap(tokenIns[i], tokenOuts[i], amountsIn[i], user);
        }
    }
    
    // ============ Internal Functions ============
    
    function _simulateSwapExecution(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address user
    ) internal view returns (uint256 amountOut) {
        // Check if using native pool
        if (_isNativePoolPair(tokenIn, tokenOut)) {
            (uint256 reserveA, uint256 reserveB,) = dashPool.getReserves();
            if (reserveA == 0 || reserveB == 0) {
                // No liquidity in pool, return simulated 1:1 rate minus 3% fee
                return (amountIn * 97) / 100;
            }
            bool isTokenAInput = tokenIn == address(dashToken);
            return dashPool.getAmountOut(amountIn, isTokenAInput, user);
        }
        
        // Use router simulation (fallback to 1:1 rate minus fee if no route)
        try smartRouter.getAmountOut(tokenIn, tokenOut, amountIn) returns (uint256 amount, bytes32) {
            amountOut = amount;
        } catch {
            amountOut = (amountIn * 97) / 100; // 3% fee simulation
        }
    }
    
    function _calculatePriceImpact(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 priceImpact) {
        if (!_isNativePoolPair(tokenIn, tokenOut)) {
            return 0; // Cannot calculate for external pools
        }
        
        (uint256 reserveA, uint256 reserveB,) = dashPool.getReserves();
        bool isTokenAInput = tokenIn == address(dashToken);
        
        uint256 reserveIn = isTokenAInput ? reserveA : reserveB;
        uint256 reserveOut = isTokenAInput ? reserveB : reserveA;
        
        if (reserveIn == 0 || reserveOut == 0) return 0;
        
        // Calculate price before and after
        uint256 priceBefore = (reserveOut * 1e18) / reserveIn;
        
        // Simulate trade
        uint256 amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = reserveOut - amountOut;
        
        uint256 priceAfter = (newReserveOut * 1e18) / newReserveIn;
        
        // Calculate impact
        if (priceBefore > priceAfter) {
            priceImpact = ((priceBefore - priceAfter) * 10000) / priceBefore;
        }
    }
    
    function _estimateGasCost(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 gasPrice
    ) internal pure returns (uint256 gasCost) {
        // Base gas estimates (simplified)
        uint256 baseGas = 21000; // Base transaction cost
        
        if (tokenIn == address(0) || tokenOut == address(0)) {
            baseGas += 30000; // ETH handling
        } else {
            baseGas += 50000; // ERC20 transfers
        }
        
        // Add router overhead
        baseGas += 100000;
        
        // Adjust for amount (larger amounts may need more gas)
        if (amountIn > 1000 ether) {
            baseGas += 20000;
        }
        
        gasCost = baseGas * gasPrice;
    }
    
    function _calculateOptimalSlippage(
        uint256 priceImpact,
        uint256 volatility
    ) internal pure returns (uint256 optimalSlippage) {
        // Base slippage is 2x price impact
        optimalSlippage = priceImpact * 2;
        
        // Add volatility buffer
        optimalSlippage += volatility;
        
        // Minimum 0.5%, maximum 5%
        if (optimalSlippage < 50) optimalSlippage = 50;
        if (optimalSlippage > 500) optimalSlippage = 500;
    }
    
    function _detectMEVRisk(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 priceImpact
    ) internal pure returns (bool mevRisk) {
        // High price impact indicates MEV opportunity
        if (priceImpact > MEV_THRESHOLD) {
            return true;
        }
        
        // Large trades are MEV targets
        if (amountIn > 100 ether) {
            return true;
        }
        
        // Popular pairs are MEV targets
        if (tokenIn == address(0) || tokenOut == address(0)) {
            return true;
        }
        
        return false;
    }
    
    function _generateOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal pure returns (bytes memory routeData) {
        // Simplified route generation
        return abi.encode(tokenIn, tokenOut, amountIn, "OPTIMAL");
    }
    
    function _generateWarnings(
        SimulationResult memory result,
        MarketConditions memory market
    ) internal pure returns (string[] memory warnings) {
        uint256 warningCount = 0;
        string[] memory tempWarnings = new string[](10);
        
        if (result.priceImpact > PRICE_IMPACT_THRESHOLD) {
            tempWarnings[warningCount] = "High price impact detected";
            warningCount++;
        }
        
        if (result.mevRisk) {
            tempWarnings[warningCount] = "MEV attack risk detected";
            warningCount++;
        }
        
        if (market.networkCongestion > 80) {
            tempWarnings[warningCount] = "Network congestion is high";
            warningCount++;
        }
        
        if (result.gasEstimate > 1 ether) {
            tempWarnings[warningCount] = "High gas cost estimated";
            warningCount++;
        }
        
        if (market.volatility > 1000) {
            tempWarnings[warningCount] = "High market volatility";
            warningCount++;
        }
        
        // Create final warnings array
        warnings = new string[](warningCount);
        for (uint256 i = 0; i < warningCount; i++) {
            warnings[i] = tempWarnings[i];
        }
    }
    
    function _getMarketConditions() internal view returns (MarketConditions memory conditions) {
        // Simplified market condition simulation
        conditions.currentGasPrice = tx.gasprice;
        conditions.networkCongestion = 50; // Mock 50% congestion
        conditions.volatility = 200; // Mock 2% volatility
        
        // Calculate liquidity depth
        (uint256 reserveA, uint256 reserveB,) = dashPool.getReserves();
        conditions.liquidityDepth = reserveA + reserveB; // Simplified
    }
    
    function _calculateImpermanentLoss(
        uint256 oldReserveA,
        uint256 oldReserveB,
        uint256 newReserveA,
        uint256 newReserveB
    ) internal pure returns (uint256 impermanentLoss) {
        if (oldReserveA == 0 || oldReserveB == 0) return 0;
        
        uint256 oldRatio = (oldReserveA * 1e18) / oldReserveB;
        uint256 newRatio = (newReserveA * 1e18) / newReserveB;
        
        // Simplified IL calculation
        if (newRatio > oldRatio) {
            impermanentLoss = ((newRatio - oldRatio) * 100) / oldRatio;
        } else {
            impermanentLoss = ((oldRatio - newRatio) * 100) / oldRatio;
        }
        
        // IL is typically much smaller
        impermanentLoss = impermanentLoss / 10;
    }
    
    function _isNativePoolPair(address tokenIn, address tokenOut) internal view returns (bool) {
        return (tokenIn == address(dashToken) && tokenOut == address(0)) ||
               (tokenIn == address(0) && tokenOut == address(dashToken));
    }
    
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Emergency function to update thresholds
     */
    function updateThresholds(
        uint256 newPriceImpactThreshold,
        uint256 newMEVThreshold
    ) external onlyOwner {
        // Would update storage variables if they weren't constants
        // This is a placeholder for future upgradability
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get detailed pool information
     */
    function getPoolInfo() external view returns (
        uint256 reserveA,
        uint256 reserveB,
        uint256 totalSupply,
        uint256 price,
        uint256 tvl
    ) {
        (reserveA, reserveB,) = dashPool.getReserves();
        totalSupply = dashPool.totalSupply();
        
        if (reserveA > 0) {
            price = (reserveB * 1e18) / reserveA;
        }
        
        tvl = reserveA + reserveB; // Simplified TVL calculation
    }
    
    /**
     * @notice Check if a swap would exceed slippage tolerance
     */
    function wouldExceedSlippage(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address user
    ) external view returns (bool exceeds, uint256 actualOutput) {
        actualOutput = _simulateSwapExecution(tokenIn, tokenOut, amountIn, user);
        exceeds = actualOutput < amountOutMin;
    }
}
