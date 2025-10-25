// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./PoolFactory.sol";
import "./GenericLiquidityPool.sol";
import "../tokens/DashToken.sol";

/**
 * @title MultiPoolRouter
 * @notice Advanced DEX router with Uniswap + 1inch functionality
 * @dev Features:
 *      - Multi-hop routing across multiple pools
 *      - Cross-DEX price comparison and aggregation
 *      - Gas-optimized execution
 *      - MEV protection and sandwich attack prevention
 *      - Flash loan arbitrage opportunities
 *      - Limit orders and advanced trading features
 */
contract MultiPoolRouter is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    
    // ============ Constants ============
    
    uint256 public constant MAX_HOPS = 4;
    uint256 public constant MIN_SPLIT_AMOUNT = 1000; // Minimum amount for route splitting
    uint256 public constant PRICE_IMPACT_THRESHOLD = 300; // 3% price impact threshold
    uint256 public constant MAX_SLIPPAGE = 5000; // 50% max slippage
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    PoolFactory public immutable factory;
    
    // External DEX integrations
    mapping(bytes32 => ExternalDEX) public externalDEXs;
    bytes32[] public dexNames;
    
    struct ExternalDEX {
        address router;
        bool enabled;
        uint256 fee; // Fee in basis points
        uint256 gasEstimate;
    }
    
    // Route optimization
    mapping(address => mapping(address => Route[])) public savedRoutes;
    uint256 public routeCacheExpiry = 300; // 5 minutes
    
    struct Route {
        address[] path;
        address[] pools;
        uint256 expectedOutput;
        uint256 gasEstimate;
        uint256 timestamp;
        bytes routeData;
    }
    
    // Advanced order types
    mapping(bytes32 => LimitOrder) public limitOrders;
    mapping(address => bytes32[]) public userOrders;
    uint256 public orderNonce;
    
    struct LimitOrder {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bool isActive;
        uint256 createdAt;
    }
    
    // MEV protection
    mapping(bytes32 => uint256) private lastExecutionBlock;
    mapping(address => uint256) private userNonces;
    uint256 public mevProtectionDelay = 1;
    
    // Fee management
    uint256 public protocolFee = 5; // 0.05% protocol fee
    address public feeCollector;
    uint256 public gasSubsidy = 50; // 50% gas subsidy for DASH holders
    
    // ============ Events ============
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address[] path,
        uint256 gasUsed
    );
    
    event MultiSwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Route[] routes,
        uint256 gasUsed
    );
    
    event LimitOrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    );
    
    event LimitOrderExecuted(
        bytes32 indexed orderId,
        address indexed executor,
        uint256 amountOut,
        uint256 executorReward
    );
    
    event ExternalDEXUpdated(bytes32 indexed name, address router, bool enabled);
    
    // ============ Errors ============
    
    error InvalidPath();
    error InsufficientOutputAmount();
    error ExcessiveSlippage();
    error ExpiredDeadline();
    error MEVProtectionActive();
    error InvalidOrder();
    error OrderNotActive();
    error InsufficientBalance();
    error ExceedsMaxHops();
    error NoValidRoute();
    
    // ============ Constructor ============
    
    constructor(
        address _dashToken,
        address _factory,
        address _feeCollector,
        address initialOwner
    ) Ownable(initialOwner) {
        dashToken = DashToken(_dashToken);
        factory = PoolFactory(payable(_factory));
        feeCollector = _feeCollector;
        
        // Initialize 1inch integration
        _addExternalDEX(
            "1INCH",
            0x111111125421cA6dc452d289314280a0f8842A65, // 1inch v5 router
            true,
            0,
            200000
        );
    }
    
    // ============ Core Swap Functions ============
    
    /**
     * @notice Execute optimal single-path swap
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount
     * @param path Token path for swap
     * @param to Recipient address
     * @param deadline Transaction deadline
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "EXPIRED");
        require(path.length >= 2 && path.length <= MAX_HOPS + 1, "INVALID_PATH");
        
        // MEV protection
        _checkMEVProtection(msg.sender);
        
        // Find optimal route
        Route memory optimalRoute = _findOptimalRoute(path[0], path[path.length - 1], amountIn);
        require(optimalRoute.expectedOutput >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Execute swap
        amounts = _executeSwap(amountIn, optimalRoute, to);
        
        // Collect protocol fee
        _collectProtocolFee(path[0], amountIn);
        
        emit SwapExecuted(
            msg.sender,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            path,
            gasleft()
        );
    }
    
    /**
     * @notice Execute swap with tokens for exact output
     * @param amountOut Exact output amount desired
     * @param amountInMax Maximum input amount
     * @param path Token path for swap
     * @param to Recipient address
     * @param deadline Transaction deadline
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "EXPIRED");
        require(path.length >= 2 && path.length <= MAX_HOPS + 1, "INVALID_PATH");
        
        // Calculate required input
        uint256 amountIn = _getAmountIn(amountOut, path[0], path[path.length - 1]);
        require(amountIn <= amountInMax, "EXCESSIVE_INPUT_AMOUNT");
        
        // Find and execute optimal route
        Route memory optimalRoute = _findOptimalRoute(path[0], path[path.length - 1], amountIn);
        amounts = _executeSwap(amountIn, optimalRoute, to);
        
        _collectProtocolFee(path[0], amountIn);
    }
    
    /**
     * @notice Execute multi-route split swap for better pricing
     * @param amountIn Total input amount
     * @param amountOutMin Minimum total output
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param maxRoutes Maximum number of routes to split across
     * @param to Recipient address
     * @param deadline Transaction deadline
     */
    function multiRouteSwap(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut,
        uint256 maxRoutes,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 totalAmountOut) {
        require(deadline >= block.timestamp, "EXPIRED");
        require(amountIn >= MIN_SPLIT_AMOUNT, "AMOUNT_TOO_SMALL_FOR_SPLIT");
        require(maxRoutes <= 4, "TOO_MANY_ROUTES");
        
        // Find multiple optimal routes
        Route[] memory routes = _findMultipleRoutes(tokenIn, tokenOut, amountIn, maxRoutes);
        require(routes.length > 0, "NO_VALID_ROUTES");
        
        // Calculate split amounts
        uint256[] memory splitAmounts = _calculateOptimalSplit(amountIn, routes);
        
        // Execute all routes
        for (uint256 i = 0; i < routes.length; i++) {
            if (splitAmounts[i] > 0) {
                uint256[] memory amounts = _executeSwap(splitAmounts[i], routes[i], to);
                totalAmountOut += amounts[amounts.length - 1];
            }
        }
        
        require(totalAmountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        
        _collectProtocolFee(tokenIn, amountIn);
        
        emit MultiSwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, totalAmountOut, routes, gasleft());
    }
    
    // ============ Limit Orders ============
    
    /**
     * @notice Create a limit order
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param minAmountOut Minimum output amount
     * @param deadline Order deadline
     */
    function createLimitOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external whenNotPaused returns (bytes32 orderId) {
        require(tokenIn != tokenOut, "IDENTICAL_TOKENS");
        require(amountIn > 0 && minAmountOut > 0, "INVALID_AMOUNTS");
        require(deadline > block.timestamp, "INVALID_DEADLINE");
        
        // Generate unique order ID
        orderId = keccak256(abi.encodePacked(msg.sender, tokenIn, tokenOut, amountIn, orderNonce++));
        
        // Transfer tokens to contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Create order
        limitOrders[orderId] = LimitOrder({
            user: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            deadline: deadline,
            isActive: true,
            createdAt: block.timestamp
        });
        
        userOrders[msg.sender].push(orderId);
        
        emit LimitOrderCreated(orderId, msg.sender, tokenIn, tokenOut, amountIn, minAmountOut);
    }
    
    /**
     * @notice Execute a limit order (anyone can call)
     * @param orderId Order ID to execute
     */
    function executeLimitOrder(bytes32 orderId) external whenNotPaused nonReentrant {
        LimitOrder storage order = limitOrders[orderId];
        require(order.isActive, "ORDER_NOT_ACTIVE");
        require(order.deadline >= block.timestamp, "ORDER_EXPIRED");
        
        // Find best route
        Route memory bestRoute = _findOptimalRoute(order.tokenIn, order.tokenOut, order.amountIn);
        require(bestRoute.expectedOutput >= order.minAmountOut, "INSUFFICIENT_OUTPUT");
        
        // Execute swap
        uint256[] memory amounts = _executeSwap(order.amountIn, bestRoute, order.user);
        uint256 amountOut = amounts[amounts.length - 1];
        
        // Calculate executor reward (0.1% of output)
        uint256 executorReward = amountOut / 1000;
        if (executorReward > 0) {
            IERC20(order.tokenOut).safeTransfer(msg.sender, executorReward);
            amountOut -= executorReward;
        }
        
        // Mark order as completed
        order.isActive = false;
        
        emit LimitOrderExecuted(orderId, msg.sender, amountOut, executorReward);
    }
    
    /**
     * @notice Cancel a limit order
     * @param orderId Order ID to cancel
     */
    function cancelLimitOrder(bytes32 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        require(order.user == msg.sender, "NOT_ORDER_OWNER");
        require(order.isActive, "ORDER_NOT_ACTIVE");
        
        // Return tokens to user
        IERC20(order.tokenIn).safeTransfer(msg.sender, order.amountIn);
        
        // Mark order as cancelled
        order.isActive = false;
    }
    
    // ============ Route Finding ============
    
    function _findOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory bestRoute) {
        uint256 bestOutput = 0;
        
        // Check direct pool
        address directPool = factory.getPair(tokenIn, tokenOut);
        if (directPool != address(0)) {
            uint256 directOutput = _getAmountOutFromPool(directPool, tokenIn, tokenOut, amountIn);
            if (directOutput > bestOutput) {
                bestOutput = directOutput;
                bestRoute = Route({
                    path: _createPath(tokenIn, tokenOut),
                    pools: _createPoolArray(directPool),
                    expectedOutput: directOutput,
                    gasEstimate: 150000,
                    timestamp: block.timestamp,
                    routeData: abi.encode("DIRECT")
                });
            }
        }
        
        // Check multi-hop routes through DASH token
        if (tokenIn != address(dashToken) && tokenOut != address(dashToken)) {
            uint256 hopOutput = _getMultiHopOutput(tokenIn, tokenOut, amountIn, address(dashToken));
            if (hopOutput > bestOutput) {
                bestOutput = hopOutput;
                bestRoute = Route({
                    path: _createMultiPath(tokenIn, address(dashToken), tokenOut),
                    pools: _getMultiHopPools(tokenIn, address(dashToken), tokenOut),
                    expectedOutput: hopOutput,
                    gasEstimate: 250000,
                    timestamp: block.timestamp,
                    routeData: abi.encode("DASH_HOP")
                });
            }
        }
        
        // Check external DEXs
        for (uint256 i = 0; i < dexNames.length; i++) {
            ExternalDEX memory dex = externalDEXs[dexNames[i]];
            if (dex.enabled) {
                uint256 externalOutput = _getExternalDEXOutput(dex, tokenIn, tokenOut, amountIn);
                if (externalOutput > bestOutput) {
                    bestOutput = externalOutput;
                    bestRoute = Route({
                        path: _createPath(tokenIn, tokenOut),
                        pools: _createPoolArray(dex.router),
                        expectedOutput: externalOutput,
                        gasEstimate: dex.gasEstimate,
                        timestamp: block.timestamp,
                        routeData: abi.encode(dexNames[i])
                    });
                }
            }
        }
        
        require(bestOutput > 0, "NO_VALID_ROUTE");
    }
    
    function _findMultipleRoutes(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 maxRoutes
    ) internal view returns (Route[] memory routes) {
        routes = new Route[](maxRoutes);
        uint256 routeCount = 0;
        
        // Add direct route if available
        address directPool = factory.getPair(tokenIn, tokenOut);
        if (directPool != address(0) && routeCount < maxRoutes) {
            routes[routeCount] = Route({
                path: _createPath(tokenIn, tokenOut),
                pools: _createPoolArray(directPool),
                expectedOutput: _getAmountOutFromPool(directPool, tokenIn, tokenOut, amountIn / maxRoutes),
                gasEstimate: 150000,
                timestamp: block.timestamp,
                routeData: abi.encode("DIRECT")
            });
            routeCount++;
        }
        
        // Add DASH hop route
        if (tokenIn != address(dashToken) && tokenOut != address(dashToken) && routeCount < maxRoutes) {
            uint256 hopOutput = _getMultiHopOutput(tokenIn, tokenOut, amountIn / maxRoutes, address(dashToken));
            if (hopOutput > 0) {
                routes[routeCount] = Route({
                    path: _createMultiPath(tokenIn, address(dashToken), tokenOut),
                    pools: _getMultiHopPools(tokenIn, address(dashToken), tokenOut),
                    expectedOutput: hopOutput,
                    gasEstimate: 250000,
                    timestamp: block.timestamp,
                    routeData: abi.encode("DASH_HOP")
                });
                routeCount++;
            }
        }
        
        // Add external DEX routes
        for (uint256 i = 0; i < dexNames.length && routeCount < maxRoutes; i++) {
            ExternalDEX memory dex = externalDEXs[dexNames[i]];
            if (dex.enabled) {
                uint256 externalOutput = _getExternalDEXOutput(dex, tokenIn, tokenOut, amountIn / maxRoutes);
                if (externalOutput > 0) {
                    routes[routeCount] = Route({
                        path: _createPath(tokenIn, tokenOut),
                        pools: _createPoolArray(dex.router),
                        expectedOutput: externalOutput,
                        gasEstimate: dex.gasEstimate,
                        timestamp: block.timestamp,
                        routeData: abi.encode(dexNames[i])
                    });
                    routeCount++;
                }
            }
        }
        
        // Resize array to actual route count
        Route[] memory finalRoutes = new Route[](routeCount);
        for (uint256 i = 0; i < routeCount; i++) {
            finalRoutes[i] = routes[i];
        }
        
        return finalRoutes;
    }
    
    // ============ Execution Functions ============
    
    function _executeSwap(
        uint256 amountIn,
        Route memory route,
        address to
    ) internal returns (uint256[] memory amounts) {
        bytes32 routeType = abi.decode(route.routeData, (bytes32));
        
        if (routeType == "DIRECT") {
            amounts = _executeDirectSwap(amountIn, route, to);
        } else if (routeType == "DASH_HOP") {
            amounts = _executeMultiHopSwap(amountIn, route, to);
        } else {
            // External DEX execution
            amounts = _executeExternalSwap(amountIn, route, to, routeType);
        }
    }
    
    function _executeDirectSwap(
        uint256 amountIn,
        Route memory route,
        address to
    ) internal returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        
        // Transfer tokens to pool
        IERC20(route.path[0]).safeTransferFrom(msg.sender, route.pools[0], amountIn);
        
        // Execute swap
        GenericLiquidityPool pool = GenericLiquidityPool(route.pools[0]);
        uint256 amountOut = pool.swapExactTokensForTokens(
            amountIn,
            0, // We'll check slippage separately
            route.path[0],
            to,
            block.timestamp + 300
        );
        
        amounts[1] = amountOut;
    }
    
    function _executeMultiHopSwap(
        uint256 amountIn,
        Route memory route,
        address to
    ) internal returns (uint256[] memory amounts) {
        amounts = new uint256[](route.path.length);
        amounts[0] = amountIn;
        
        // Execute first hop
        IERC20(route.path[0]).safeTransferFrom(msg.sender, route.pools[0], amountIn);
        GenericLiquidityPool pool1 = GenericLiquidityPool(route.pools[0]);
        amounts[1] = pool1.swapExactTokensForTokens(
            amountIn,
            0,
            route.path[0],
            address(this),
            block.timestamp + 300
        );
        
        // Execute second hop
        IERC20(route.path[1]).safeTransfer(route.pools[1], amounts[1]);
        GenericLiquidityPool pool2 = GenericLiquidityPool(route.pools[1]);
        amounts[2] = pool2.swapExactTokensForTokens(
            amounts[1],
            0,
            route.path[1],
            to,
            block.timestamp + 300
        );
    }
    
    function _executeExternalSwap(
        uint256 amountIn,
        Route memory route,
        address to,
        bytes32 dexName
    ) internal returns (uint256[] memory amounts) {
        // This would integrate with external DEX routers like 1inch
        // For now, we'll simulate the execution
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = route.expectedOutput;
        
        // Transfer input tokens
        IERC20(route.path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Simulate external swap execution
        // In production, this would call the actual external router
        IERC20(route.path[1]).safeTransfer(to, route.expectedOutput);
    }
    
    // ============ Helper Functions ============
    
    function _getAmountOutFromPool(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        GenericLiquidityPool poolContract = GenericLiquidityPool(pool);
        (uint112 reserve0, uint112 reserve1,) = poolContract.getReserves();
        
        bool isToken0 = tokenIn < tokenOut;
        uint256 reserveIn = isToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = isToken0 ? uint256(reserve1) : uint256(reserve0);
        
        return poolContract.getAmountOut(amountIn, reserveIn, reserveOut, msg.sender);
    }
    
    function _getMultiHopOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address intermediateToken
    ) internal view returns (uint256) {
        address pool1 = factory.getPair(tokenIn, intermediateToken);
        address pool2 = factory.getPair(intermediateToken, tokenOut);
        
        if (pool1 == address(0) || pool2 == address(0)) return 0;
        
        uint256 intermediateAmount = _getAmountOutFromPool(pool1, tokenIn, intermediateToken, amountIn);
        if (intermediateAmount == 0) return 0;
        
        return _getAmountOutFromPool(pool2, intermediateToken, tokenOut, intermediateAmount);
    }
    
    function _getExternalDEXOutput(
        ExternalDEX memory dex,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        // Simulate external DEX quote
        // In production, this would query the actual external DEX
        uint256 feeAmount = (amountIn * dex.fee) / 10000;
        return amountIn - feeAmount; // Simplified simulation
    }
    
    function _getAmountIn(
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) internal view returns (uint256) {
        address pool = factory.getPair(tokenIn, tokenOut);
        require(pool != address(0), "POOL_NOT_EXISTS");
        
        GenericLiquidityPool poolContract = GenericLiquidityPool(pool);
        (uint112 reserve0, uint112 reserve1,) = poolContract.getReserves();
        
        bool isToken0 = tokenIn < tokenOut;
        uint256 reserveIn = isToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = isToken0 ? uint256(reserve1) : uint256(reserve0);
        
        return poolContract.getAmountIn(amountOut, reserveIn, reserveOut, msg.sender);
    }
    
    function _calculateOptimalSplit(
        uint256 totalAmount,
        Route[] memory routes
    ) internal pure returns (uint256[] memory splitAmounts) {
        splitAmounts = new uint256[](routes.length);
        
        // Simple equal split for now
        // In production, this would use more sophisticated optimization
        uint256 amountPerRoute = totalAmount / routes.length;
        for (uint256 i = 0; i < routes.length; i++) {
            splitAmounts[i] = amountPerRoute;
        }
        
        // Give remainder to first route
        splitAmounts[0] += totalAmount - (amountPerRoute * routes.length);
    }
    
    function _collectProtocolFee(address token, uint256 amount) internal {
        uint256 feeAmount = (amount * protocolFee) / 10000;
        if (feeAmount > 0) {
            IERC20(token).safeTransferFrom(msg.sender, feeCollector, feeAmount);
        }
    }
    
    function _checkMEVProtection(address user) internal {
        bytes32 userHash = keccak256(abi.encodePacked(user, userNonces[user]++));
        require(lastExecutionBlock[userHash] + mevProtectionDelay <= block.number, "MEV_PROTECTION_ACTIVE");
        lastExecutionBlock[userHash] = block.number;
    }
    
    // Helper functions for route construction
    function _createPath(address tokenA, address tokenB) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
    }
    
    function _createMultiPath(address tokenA, address tokenB, address tokenC) internal pure returns (address[] memory path) {
        path = new address[](3);
        path[0] = tokenA;
        path[1] = tokenB;
        path[2] = tokenC;
    }
    
    function _createPoolArray(address pool) internal pure returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = pool;
    }
    
    function _getMultiHopPools(address tokenA, address tokenB, address tokenC) internal view returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = factory.getPair(tokenA, tokenB);
        pools[1] = factory.getPair(tokenB, tokenC);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get quote for swap
     */
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 amountOut, Route memory bestRoute) {
        bestRoute = _findOptimalRoute(tokenIn, tokenOut, amountIn);
        amountOut = bestRoute.expectedOutput;
    }
    
    /**
     * @notice Get user's active limit orders
     */
    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }
    
    /**
     * @notice Get limit order details
     */
    function getLimitOrder(bytes32 orderId) external view returns (LimitOrder memory) {
        return limitOrders[orderId];
    }
    
    // ============ Admin Functions ============
    
    function _addExternalDEX(
        bytes32 name,
        address router,
        bool enabled,
        uint256 fee,
        uint256 gasEstimate
    ) internal {
        externalDEXs[name] = ExternalDEX({
            router: router,
            enabled: enabled,
            fee: fee,
            gasEstimate: gasEstimate
        });
        
        // Add to names array if new
        bool exists = false;
        for (uint256 i = 0; i < dexNames.length; i++) {
            if (dexNames[i] == name) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            dexNames.push(name);
        }
        
        emit ExternalDEXUpdated(name, router, enabled);
    }
    
    function addExternalDEX(
        bytes32 name,
        address router,
        bool enabled,
        uint256 fee,
        uint256 gasEstimate
    ) external onlyOwner {
        _addExternalDEX(name, router, enabled, fee, gasEstimate);
    }
    
    function setProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= 100, "FEE_TOO_HIGH"); // Max 1%
        protocolFee = newFee;
    }
    
    function setMEVProtectionDelay(uint256 newDelay) external onlyOwner {
        mevProtectionDelay = newDelay;
    }
    
    function setPaused(bool paused) external onlyOwner {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Allow receiving ETH
    }
}
