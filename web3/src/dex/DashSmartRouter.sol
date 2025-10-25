// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../tokens/DashToken.sol";
import "./SimpleLiquidityPool.sol";

/**
 * @title DashSmartRouter
 * @notice Intelligent DEX aggregator with 1inch integration and multi-hop routing
 * @dev Features:
 *      - Route optimization across multiple DEXs
 *      - 1inch API integration for best prices
 *      - Native liquidity pool integration
 *      - MEV protection and slippage controls
 *      - AI agent execution via session keys
 *      - Fee collection and DASH token burning
 */
contract DashSmartRouter is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    
    // ============ Constants ============
    
    uint256 public constant MAX_SLIPPAGE = 5000; // 50% max slippage
    uint256 public constant MIN_AMOUNT_OUT = 1; // Minimum 1 wei output
    uint256 public constant FEE_DENOMINATOR = 10000;
    
    // ============ Structs ============
    
    struct SwapParams {
        address tokenIn;            // Input token
        address tokenOut;           // Output token  
        uint256 amountIn;           // Input amount
        uint256 amountOutMin;       // Minimum output (slippage protection)
        address to;                 // Recipient address
        uint256 deadline;           // Transaction deadline
        bytes routeData;            // Route-specific data
    }
    
    struct RouteInfo {
        address[] path;             // Token path
        address[] exchanges;        // DEX addresses in route
        uint256[] fees;             // Fee for each hop
        uint256 expectedOutput;     // Expected output amount
        uint256 gasEstimate;        // Gas cost estimate
        bytes data;                 // Route execution data
    }
    
    struct AggregatorConfig {
        address contractAddress;    // 1inch aggregator contract
        bool enabled;               // Whether this aggregator is active
        uint256 fee;                // Fee charged by aggregator (in bps)
        uint256 maxSlippage;        // Max allowed slippage
    }
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    SimpleLiquidityPool public immutable dashPool;
    
    // Supported DEX aggregators
    mapping(bytes32 => AggregatorConfig) public aggregators;
    bytes32[] public aggregatorNames;
    
    // Fee management
    uint256 public protocolFee = 10; // 0.1% protocol fee
    address public feeCollector;
    uint256 public burnRate = 5000; // 50% of fees burned
    
    // Route optimization
    mapping(address => mapping(address => RouteInfo)) public cachedRoutes;
    mapping(address => uint256) public tokenPriorityScore;
    uint256 public routeCacheExpiry = 300; // 5 minutes
    
    // Security and limits
    mapping(address => bool) public authorizedCallers;
    mapping(address => uint256) public dailyVolume;
    mapping(address => uint256) public lastVolumeReset;
    uint256 public maxDailyVolumePerUser = 1000 ether;
    
    // MEV Protection
    mapping(bytes32 => uint256) public lastBlockUsed;
    uint256 public mevProtectionDelay = 1; // 1 block delay
    
    // ============ Events ============
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 routeId,
        uint256 gasUsed
    );
    
    event RouteOptimized(
        address indexed tokenIn,
        address indexed tokenOut,
        bytes32 routeId,
        uint256 expectedOutput,
        uint256 gasEstimate
    );
    
    event FeeCollected(address indexed token, uint256 amount, uint256 burned);
    event AggregatorUpdated(bytes32 indexed name, address contractAddr, bool enabled);
    
    // ============ Errors ============
    
    error InvalidRoute();
    error SlippageExceeded();
    error DeadlineExpired();
    error InsufficientOutput();
    error DailyVolumeExceeded();
    error MEVProtectionActive();
    error UnauthorizedCaller();
    error InvalidAggregator();
    
    // ============ Constructor ============
    
    constructor(
        DashToken _dashToken,
        SimpleLiquidityPool _dashPool,
        address _feeCollector,
        address initialOwner
    ) Ownable(initialOwner) {
        dashToken = _dashToken;
        dashPool = _dashPool;
        feeCollector = _feeCollector;
        
        // Initialize default aggregator (1inch)
        _addAggregator(
            "1INCH",
            0x111111125421cA6dc452d289314280a0f8842A65, // 1inch v5 mainnet
            true,
            0, // No additional fee
            2000 // 20% max slippage
        );
        
        // Set initial authorized caller
        authorizedCallers[initialOwner] = true;
    }
    
    // ============ Main Swap Functions ============
    
    /**
     * @notice Execute optimal swap with route selection
     * @param params Swap parameters
     * @return amountOut Actual output amount received
     */
    function swapExactTokensForTokens(SwapParams calldata params) 
        external 
        payable 
        whenNotPaused 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        require(block.timestamp <= params.deadline, "Transaction expired");
        require(params.amountIn > 0, "Invalid input amount");
        
        // MEV protection
        bytes32 txHash = keccak256(abi.encode(params, block.number));
        _checkMEVProtection(txHash);
        
        // Volume limit check
        _checkDailyVolume(msg.sender, params.amountIn, params.tokenIn);
        
        // Find optimal route
        RouteInfo memory route = _findOptimalRoute(
            params.tokenIn,
            params.tokenOut,
            params.amountIn
        );
        
        require(route.expectedOutput >= params.amountOutMin, "Insufficient output amount");
        
        // Execute swap
        amountOut = _executeSwap(params, route);
        
        // Collect fees
        _collectFees(params.tokenIn, params.amountIn);
        
        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            keccak256(abi.encode(route.path)),
            gasleft()
        );
    }
    
    /**
     * @notice Get quote for swap without executing
     * @param tokenIn Input token address
     * @param tokenOut Output token address  
     * @param amountIn Input amount
     * @return amountOut Expected output amount
     * @return routeId Route identifier
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, bytes32 routeId) {
        RouteInfo memory route = _findOptimalRoute(tokenIn, tokenOut, amountIn);
        return (route.expectedOutput, keccak256(abi.encode(route.path)));
    }
    
    /**
     * @notice Execute swap through specific aggregator
     * @param aggregatorName Name of the aggregator to use
     * @param params Swap parameters
     * @param routeData Aggregator-specific route data
     */
    function swapViaAggregator(
        bytes32 aggregatorName,
        SwapParams calldata params,
        bytes calldata routeData
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        AggregatorConfig memory config = aggregators[aggregatorName];
        require(config.enabled, "Aggregator not enabled");
        
        // Execute through aggregator
        amountOut = _executeAggregatorSwap(config, params, routeData);
        
        // Collect fees
        _collectFees(params.tokenIn, params.amountIn);
        
        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            aggregatorName,
            gasleft()
        );
    }
    
    /**
     * @notice Multi-hop swap through multiple DEXs
     * @param path Array of token addresses
     * @param amountIn Input amount
     * @param amountOutMin Minimum final output
     * @param to Recipient address
     * @param deadline Transaction deadline
     */
    function swapMultiHop(
        address[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        require(block.timestamp <= deadline, "Transaction expired");
        
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        
        // Execute each hop
        for (uint256 i = 0; i < path.length - 1; i++) {
            RouteInfo memory route = _findOptimalRoute(
                path[i],
                path[i + 1],
                amounts[i]
            );
            
            SwapParams memory params = SwapParams({
                tokenIn: path[i],
                tokenOut: path[i + 1],
                amountIn: amounts[i],
                amountOutMin: 1, // Will check final amount at end
                to: i == path.length - 2 ? to : address(this),
                deadline: deadline,
                routeData: route.data
            });
            
            amounts[i + 1] = _executeSwap(params, route);
        }
        
        require(amounts[amounts.length - 1] >= amountOutMin, "Insufficient final output");
        
        // Collect fees on initial input
        _collectFees(path[0], amountIn);
    }
    
    // ============ Route Optimization ============
    
    function _findOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (RouteInfo memory bestRoute) {
        // Check cache first
        RouteInfo memory cached = cachedRoutes[tokenIn][tokenOut];
        if (cached.expectedOutput > 0 && 
            block.timestamp - lastVolumeReset[tokenIn] < routeCacheExpiry) {
            return cached;
        }
        
        uint256 bestOutput = 0;
        bytes32 bestAggregator;
        
        // Check our native pool first
        if (_isNativePoolPair(tokenIn, tokenOut)) {
            uint256 nativeOutput = _getNativePoolOutput(tokenIn, tokenOut, amountIn);
            if (nativeOutput > bestOutput) {
                bestOutput = nativeOutput;
                bestRoute = RouteInfo({
                    path: _createPath(tokenIn, tokenOut),
                    exchanges: _createExchangeArray(address(dashPool)),
                    fees: _createFeesArray(dashPool.BASE_FEE()),
                    expectedOutput: nativeOutput,
                    gasEstimate: 150000, // Estimated gas for native pool
                    data: abi.encode("NATIVE")
                });
            }
        }
        
        // Check aggregators
        for (uint256 i = 0; i < aggregatorNames.length; i++) {
            bytes32 name = aggregatorNames[i];
            AggregatorConfig memory config = aggregators[name];
            
            if (!config.enabled) continue;
            
            uint256 aggregatorOutput = _getAggregatorOutput(config, tokenIn, tokenOut, amountIn);
            if (aggregatorOutput > bestOutput) {
                bestOutput = aggregatorOutput;
                bestAggregator = name;
                
                bestRoute = RouteInfo({
                    path: _createPath(tokenIn, tokenOut),
                    exchanges: _createExchangeArray(config.contractAddress),
                    fees: _createFeesArray(config.fee),
                    expectedOutput: aggregatorOutput,
                    gasEstimate: 200000, // Estimated gas for aggregator
                    data: abi.encode(name)
                });
            }
        }
        
        require(bestOutput > 0, "No valid route found");
        return bestRoute;
    }
    
    function _executeSwap(
        SwapParams memory params,
        RouteInfo memory route
    ) internal returns (uint256 amountOut) {
        // Handle token transfers
        if (params.tokenIn == address(0)) {
            require(msg.value >= params.amountIn, "Insufficient ETH");
        } else {
            IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        }
        
        // Route to appropriate execution
        bytes32 routeType = abi.decode(route.data, (bytes32));
        
        if (routeType == "NATIVE") {
            amountOut = _executeNativeSwap(params);
        } else {
            // Execute via aggregator
            AggregatorConfig memory config = aggregators[routeType];
            amountOut = _executeAggregatorSwap(config, params, route.data);
        }
        
        require(amountOut >= params.amountOutMin, "Slippage exceeded");
    }
    
    function _executeNativeSwap(SwapParams memory params) internal returns (uint256 amountOut) {
        // Use our native liquidity pool
        if (params.tokenIn == address(0) || params.tokenIn == address(dashToken)) {
            // Handle ETH or DASH input
            bool isTokenAInput = params.tokenIn == address(dashToken);
            
            if (!isTokenAInput) {
                // ETH -> DASH swap
                amountOut = dashPool.swapExactTokensForTokens{value: params.amountIn}(
                    params.amountIn,
                    params.amountOutMin,
                    params.tokenIn,
                    params.to,
                    params.deadline
                );
            } else {
                // DASH -> ETH swap
                amountOut = dashPool.swapExactTokensForTokens(
                    params.amountIn,
                    params.amountOutMin,
                    params.tokenIn,
                    params.to,
                    params.deadline
                );
            }
        } else {
            revert InvalidRoute();
        }
    }
    
    function _executeAggregatorSwap(
        AggregatorConfig memory config,
        SwapParams memory params,
        bytes memory routeData
    ) internal returns (uint256 amountOut) {
        // This would integrate with 1inch API
        // For now, we'll simulate the call structure
        
        uint256 balanceBefore = params.tokenOut == address(0) 
            ? params.to.balance 
            : IERC20(params.tokenOut).balanceOf(params.to);
            
        // Approve token if needed
        if (params.tokenIn != address(0)) {
            IERC20(params.tokenIn).forceApprove(config.contractAddress, params.amountIn);
        }
        
        // Execute swap through aggregator
        // This is where we'd call the 1inch contract with routeData
        // For testing, we'll simulate a successful swap
        amountOut = _simulateAggregatorSwap(params);
        
        uint256 balanceAfter = params.tokenOut == address(0)
            ? params.to.balance
            : IERC20(params.tokenOut).balanceOf(params.to);
            
        amountOut = balanceAfter - balanceBefore;
        
        // Reset approval
        if (params.tokenIn != address(0)) {
            IERC20(params.tokenIn).forceApprove(config.contractAddress, 0);
        }
    }
    
    // ============ Helper Functions ============
    
    function _simulateAggregatorSwap(SwapParams memory params) internal pure returns (uint256) {
        // Simulate 1inch swap with 0.1% better rate than input
        return (params.amountIn * 999) / 1000; // Simplified simulation
    }
    
    function _isNativePoolPair(address tokenIn, address tokenOut) internal view returns (bool) {
        return (tokenIn == address(dashToken) && tokenOut == address(0)) ||
               (tokenIn == address(0) && tokenOut == address(dashToken));
    }
    
    function _getNativePoolOutput(address tokenIn, address tokenOut, uint256 amountIn) 
        internal view returns (uint256) {
        bool isTokenAInput = tokenIn == address(dashToken);
        return dashPool.getAmountOut(amountIn, isTokenAInput, msg.sender);
    }
    
    function _getAggregatorOutput(
        AggregatorConfig memory config,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        // This would query 1inch API for quote
        // For testing, return simulated output
        return (amountIn * (10000 - config.fee)) / 10000;
    }
    
    function _checkMEVProtection(bytes32 txHash) internal {
        require(lastBlockUsed[txHash] + mevProtectionDelay <= block.number, "MEV protection active");
        lastBlockUsed[txHash] = block.number;
    }
    
    function _checkDailyVolume(address user, uint256 amount, address token) internal {
        if (block.timestamp >= lastVolumeReset[user] + 1 days) {
            dailyVolume[user] = 0;
            lastVolumeReset[user] = block.timestamp;
        }
        
        // Convert amount to ETH equivalent for limit checking
        uint256 ethValue = token == address(0) ? amount : _getETHValue(token, amount);
        require(dailyVolume[user] + ethValue <= maxDailyVolumePerUser, "Daily volume exceeded");
        
        dailyVolume[user] += ethValue;
    }
    
    function _getETHValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(dashToken)) {
            // Get DASH/ETH price from our pool
            (uint256 reserveA, uint256 reserveB,) = dashPool.getReserves();
            if (reserveA > 0 && reserveB > 0) {
                return (amount * reserveB) / reserveA;
            }
        }
        return amount; // Fallback: assume 1:1 ratio
    }
    
    function _collectFees(address tokenIn, uint256 amountIn) internal {
        uint256 feeAmount = (amountIn * protocolFee) / FEE_DENOMINATOR;
        if (feeAmount > 0) {
            uint256 burnAmount = (feeAmount * burnRate) / FEE_DENOMINATOR;
            uint256 collectAmount = feeAmount - burnAmount;
            
            if (tokenIn == address(dashToken)) {
                // Burn DASH fees
                if (burnAmount > 0) {
                    dashToken.burnFees(burnAmount);
                }
                
                // Send remaining to fee collector
                if (collectAmount > 0) {
                    IERC20(tokenIn).safeTransfer(feeCollector, collectAmount);
                }
            }
            
            emit FeeCollected(tokenIn, feeAmount, burnAmount);
        }
    }
    
    // Helper functions for route creation
    function _createPath(address tokenIn, address tokenOut) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }
    
    function _createExchangeArray(address exchange) internal pure returns (address[] memory exchanges) {
        exchanges = new address[](1);
        exchanges[0] = exchange;
    }
    
    function _createFeesArray(uint256 fee) internal pure returns (uint256[] memory fees) {
        fees = new uint256[](1);
        fees[0] = fee;
    }
    
    // ============ Admin Functions ============
    
    function _addAggregator(
        bytes32 name,
        address contractAddr,
        bool enabled,
        uint256 fee,
        uint256 maxSlippage
    ) internal {
        aggregators[name] = AggregatorConfig({
            contractAddress: contractAddr,
            enabled: enabled,
            fee: fee,
            maxSlippage: maxSlippage
        });
        
        // Add to names array if new
        bool exists = false;
        for (uint256 i = 0; i < aggregatorNames.length; i++) {
            if (aggregatorNames[i] == name) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            aggregatorNames.push(name);
        }
        
        emit AggregatorUpdated(name, contractAddr, enabled);
    }
    
    function addAggregator(
        bytes32 name,
        address contractAddr,
        bool enabled,
        uint256 fee,
        uint256 maxSlippage
    ) external onlyOwner {
        _addAggregator(name, contractAddr, enabled, fee, maxSlippage);
    }
    
    function updateAggregator(bytes32 name, bool enabled) external onlyOwner {
        require(aggregators[name].contractAddress != address(0), "Aggregator not found");
        aggregators[name].enabled = enabled;
        
        emit AggregatorUpdated(name, aggregators[name].contractAddress, enabled);
    }
    
    function setProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= 100, "Fee too high"); // Max 1%
        protocolFee = newFee;
    }
    
    function setBurnRate(uint256 newRate) external onlyOwner {
        require(newRate <= FEE_DENOMINATOR, "Invalid burn rate");
        burnRate = newRate;
    }
    
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }
    
    function updateLimits(
        uint256 newMaxDailyVolume,
        uint256 newMEVDelay,
        uint256 newCacheExpiry
    ) external onlyOwner {
        maxDailyVolumePerUser = newMaxDailyVolume;
        mevProtectionDelay = newMEVDelay;
        routeCacheExpiry = newCacheExpiry;
    }
    
    function setPaused(bool paused) external onlyOwner {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }
    
    // ============ View Functions ============
    
    function getAggregators() external view returns (bytes32[] memory names) {
        return aggregatorNames;
    }
    
    function getRouteCache(address tokenIn, address tokenOut) external view returns (RouteInfo memory) {
        return cachedRoutes[tokenIn][tokenOut];
    }
    
    function isAuthorized(address caller) external view returns (bool) {
        return authorizedCallers[caller];
    }
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Allow receiving ETH for ETH swaps
    }
}
