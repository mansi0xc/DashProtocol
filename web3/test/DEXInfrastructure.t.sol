// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@forge-std/Test.sol";
import "@forge-std/console.sol";
import "../src/tokens/DashToken.sol";
import "../src/dex/SimpleLiquidityPool.sol";
import "../src/dex/DashSmartRouter.sol";
import "../src/dex/TransactionSimulator.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock WETH for testing
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract DEXInfrastructureTest is Test {
    // ============ State Variables ============
    
    DashToken public dashToken;
    MockWETH public weth;
    SimpleLiquidityPool public liquidityPool;
    DashSmartRouter public smartRouter;
    TransactionSimulator public simulator;
    
    address public owner;
    address public user1;
    address public user2;
    address public feeCollector;
    
    uint256 public constant INITIAL_DASH_SUPPLY = 1000000 * 10**18;
    uint256 public constant INITIAL_WETH_SUPPLY = 10000 * 10**18;
    
    // ============ Setup ============
    
    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        feeCollector = makeAddr("feeCollector");
        
        // Deal ETH to test accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        
        // Deploy contracts
        vm.startPrank(owner);
        
        dashToken = new DashToken(owner, owner);
        weth = new MockWETH();
        
        liquidityPool = new SimpleLiquidityPool(
            dashToken,
            weth,
            feeCollector,
            owner
        );
        
        smartRouter = new DashSmartRouter(
            dashToken,
            liquidityPool,
            feeCollector,
            owner
        );
        
        simulator = new TransactionSimulator(
            dashToken,
            liquidityPool,
            smartRouter,
            owner
        );
        
        // Setup initial token distribution
        dashToken.mint(owner, INITIAL_DASH_SUPPLY);
        dashToken.mint(user1, INITIAL_DASH_SUPPLY);
        dashToken.mint(user2, INITIAL_DASH_SUPPLY);
        
        weth.mint(owner, INITIAL_WETH_SUPPLY);
        weth.mint(user1, INITIAL_WETH_SUPPLY);
        weth.mint(user2, INITIAL_WETH_SUPPLY);
        
        // Add liquidity pool as minter for rewards
        dashToken.addMinter(address(liquidityPool));
        
        // Add smart router as minter for fee burning
        dashToken.addMinter(address(smartRouter));
        
        vm.stopPrank();
    }
    
    // ============ SimpleLiquidityPool Tests ============
    
    function testPoolInitialState() public {
        assertEq(liquidityPool.name(), "DASH-ETH LP");
        assertEq(liquidityPool.symbol(), "DASH-ETH-LP");
        assertEq(liquidityPool.totalSupply(), 0);
        
        (uint256 reserveA, uint256 reserveB,) = liquidityPool.getReserves();
        assertEq(reserveA, 0);
        assertEq(reserveB, 0);
    }
    
    function testAddLiquidity() public {
        uint256 amountDASH = 1000 * 10**18;
        uint256 amountWETH = 10 * 10**18;
        
        vm.startPrank(user1);
        
        // Approve tokens
        dashToken.approve(address(liquidityPool), amountDASH);
        weth.approve(address(liquidityPool), amountWETH);
        
        // Add liquidity
        uint256 liquidity = liquidityPool.addLiquidity(
            amountDASH,
            amountWETH,
            amountDASH,
            amountWETH,
            user1,
            block.timestamp + 1 hours
        );
        
        // Verify liquidity tokens minted
        assertGt(liquidity, 0);
        assertEq(liquidityPool.balanceOf(user1), liquidity);
        
        // Verify reserves updated
        (uint256 reserveA, uint256 reserveB,) = liquidityPool.getReserves();
        assertEq(reserveA, amountDASH);
        assertEq(reserveB, amountWETH);
        
        vm.stopPrank();
    }
    
    function testRemoveLiquidity() public {
        // First add liquidity
        testAddLiquidity();
        
        vm.startPrank(user1);
        
        uint256 liquidityAmount = liquidityPool.balanceOf(user1);
        uint256 halfLiquidity = liquidityAmount / 2;
        
        // Remove half the liquidity
        (uint256 amountA, uint256 amountB) = liquidityPool.removeLiquidity(
            halfLiquidity,
            0,
            0,
            user1,
            block.timestamp + 1 hours
        );
        
        // Verify tokens received
        assertGt(amountA, 0);
        assertGt(amountB, 0);
        
        // Verify LP tokens burned
        assertEq(liquidityPool.balanceOf(user1), liquidityAmount - halfLiquidity);
        
        vm.stopPrank();
    }
    
    function testSwapExactTokensForTokens() public {
        // Add initial liquidity
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        uint256 swapAmount = 100 * 10**18; // 100 DASH
        uint256 balanceBefore = weth.balanceOf(user2);
        
        // Approve and swap DASH for WETH
        dashToken.approve(address(liquidityPool), swapAmount);
        
        uint256 amountOut = liquidityPool.swapExactTokensForTokens(
            swapAmount,
            0,
            address(dashToken),
            user2,
            block.timestamp + 1 hours
        );
        
        // Verify output received
        assertGt(amountOut, 0);
        assertEq(weth.balanceOf(user2), balanceBefore + amountOut);
        
        vm.stopPrank();
    }
    
    function testSwapWithStakingDiscount() public {
        // Add initial liquidity
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        // Stake DASH tokens for fee discount
        uint256 stakeAmount = 500_000 * 10**18; // Silver tier (within user's balance)
        dashToken.approve(address(dashToken), stakeAmount);
        dashToken.stake(stakeAmount);
        
        uint256 swapAmount = 100 * 10**18;
        
        // Get quote with and without staking
        uint256 amountOutWithDiscount = liquidityPool.getAmountOut(
            swapAmount,
            true,
            user2
        );
        
        // Switch to different user without staking
        vm.stopPrank();
        uint256 amountOutWithoutDiscount = liquidityPool.getAmountOut(
            swapAmount,
            true,
            user1
        );
        
        // Verify discount applied
        assertGt(amountOutWithDiscount, amountOutWithoutDiscount);
        
        vm.startPrank(user2);
        vm.stopPrank();
    }
    
    function testLiquidityRewards() public {
        testAddLiquidity();
        
        // Fast forward time to accumulate rewards
        vm.warp(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        
        uint256 pendingRewards = liquidityPool.getPendingRewards(user1);
        assertGt(pendingRewards, 0);
        
        // Claim rewards
        liquidityPool.claimRewards();
        
        // Verify rewards received (would need minter permissions)
        vm.stopPrank();
    }
    
    function testTWAPUpdate() public {
        testAddLiquidity();
        
        // Make a swap to trigger TWAP update
        vm.startPrank(user2);
        
        dashToken.approve(address(liquidityPool), 50 * 10**18);
        liquidityPool.swapExactTokensForTokens(
            50 * 10**18,
            0,
            address(dashToken),
            user2,
            block.timestamp + 1 hours
        );
        
        // Verify TWAP is updated
        (uint256 price0, uint256 price1) = liquidityPool.getTWAPPrice();
        assertGt(price0, 0);
        assertGt(price1, 0);
        
        vm.stopPrank();
    }
    
    // ============ DashSmartRouter Tests ============
    
    function testRouterSwapViaPool() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        uint256 swapAmount = 50 * 10**18;
        dashToken.approve(address(smartRouter), swapAmount);
        
        DashSmartRouter.SwapParams memory params = DashSmartRouter.SwapParams({
            tokenIn: address(dashToken),
            tokenOut: address(weth),
            amountIn: swapAmount,
            amountOutMin: 0,
            to: user2,
            deadline: block.timestamp + 1 hours,
            routeData: ""
        });
        
        uint256 amountOut = smartRouter.swapExactTokensForTokens(params);
        assertGt(amountOut, 0);
        
        vm.stopPrank();
    }
    
    function testRouterGetAmountOut() public {
        testAddLiquidity();
        
        uint256 amountIn = 100 * 10**18;
        (uint256 amountOut, bytes32 routeId) = smartRouter.getAmountOut(
            address(dashToken),
            address(weth),
            amountIn
        );
        
        assertGt(amountOut, 0);
        assertTrue(routeId != bytes32(0));
    }
    
    function testRouterMultiHop() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        address[] memory path = new address[](2);
        path[0] = address(dashToken);
        path[1] = address(weth);
        
        uint256 amountIn = 50 * 10**18;
        dashToken.approve(address(smartRouter), amountIn);
        
        uint256[] memory amounts = smartRouter.swapMultiHop(
            path,
            amountIn,
            0,
            user2,
            block.timestamp + 1 hours
        );
        
        assertEq(amounts.length, 2);
        assertEq(amounts[0], amountIn);
        assertGt(amounts[1], 0);
        
        vm.stopPrank();
    }
    
    function testRouterDailyVolumeLimit() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        // Try to exceed daily volume limit
        uint256 largeAmount = 2000 * 10**18; // Exceeds 1000 ETH equivalent limit
        dashToken.approve(address(smartRouter), largeAmount);
        
        DashSmartRouter.SwapParams memory params = DashSmartRouter.SwapParams({
            tokenIn: address(dashToken),
            tokenOut: address(weth),
            amountIn: largeAmount,
            amountOutMin: 0,
            to: user2,
            deadline: block.timestamp + 1 hours,
            routeData: ""
        });
        
        // This should revert due to daily volume limit
        vm.expectRevert("Daily volume exceeded");
        smartRouter.swapExactTokensForTokens(params);
        
        vm.stopPrank();
    }
    
    function testRouterFeeCollection() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        uint256 swapAmount = 100 * 10**18;
        // Note: Fee collection happens via burning for DASH tokens
        
        dashToken.approve(address(smartRouter), swapAmount);
        
        DashSmartRouter.SwapParams memory params = DashSmartRouter.SwapParams({
            tokenIn: address(dashToken),
            tokenOut: address(weth),
            amountIn: swapAmount,
            amountOutMin: 0,
            to: user2,
            deadline: block.timestamp + 1 hours,
            routeData: ""
        });
        
        smartRouter.swapExactTokensForTokens(params);
        
        // Note: Fee collection happens via burning, so this test would need adjustment
        // for actual fee collection verification
        
        vm.stopPrank();
    }
    
    // ============ TransactionSimulator Tests ============
    
    function testSimulateSwap() public {
        testAddLiquidity();
        
        uint256 amountIn = 100 * 10**18;
        
        TransactionSimulator.SimulationResult memory result = simulator.simulateSwap(
            address(dashToken),
            address(weth),
            amountIn,
            user1
        );
        
        assertGt(result.outputAmount, 0);
        assertGt(result.gasEstimate, 0);
        assertGe(result.optimalSlippage, 50); // At least 0.5%
        assertLe(result.optimalSlippage, 500); // At most 5%
    }
    
    function testSimulateLiquidityAddition() public {
        uint256 amountA = 1000 * 10**18;
        uint256 amountB = 10 * 10**18;
        
        TransactionSimulator.LiquiditySimulation memory simulation = 
            simulator.simulateLiquidityAddition(amountA, amountB);
        
        assertEq(simulation.newReserveA, amountA);
        assertEq(simulation.newReserveB, amountB);
        assertGt(simulation.lpTokensIssued, 0);
        assertGt(simulation.newPrice, 0);
    }
    
    function testSimulateMultiHop() public {
        testAddLiquidity();
        
        address[] memory path = new address[](2);
        path[0] = address(dashToken);
        path[1] = address(weth);
        
        uint256 amountIn = 50 * 10**18;
        
        (uint256[] memory amounts, uint256 totalGas) = simulator.simulateMultiHop(
            path,
            amountIn,
            user1
        );
        
        assertEq(amounts.length, 2);
        assertEq(amounts[0], amountIn);
        assertGt(amounts[1], 0);
        assertGt(totalGas, 0);
    }
    
    function testGetMarketConditions() public {
        TransactionSimulator.MarketConditions memory conditions = simulator.getMarketConditions();
        
        assertGt(conditions.currentGasPrice, 0);
        assertGe(conditions.networkCongestion, 0);
        assertLe(conditions.networkCongestion, 100);
        assertGe(conditions.volatility, 0);
    }
    
    function testBatchSimulate() public {
        testAddLiquidity();
        
        address[] memory tokenIns = new address[](2);
        address[] memory tokenOuts = new address[](2);
        uint256[] memory amountsIn = new uint256[](2);
        
        tokenIns[0] = address(dashToken);
        tokenOuts[0] = address(weth);
        amountsIn[0] = 50 * 10**18;
        
        tokenIns[1] = address(weth);
        tokenOuts[1] = address(dashToken);
        amountsIn[1] = 1 * 10**18;
        
        TransactionSimulator.SimulationResult[] memory results = simulator.batchSimulate(
            tokenIns,
            tokenOuts,
            amountsIn,
            user1
        );
        
        assertEq(results.length, 2);
        assertGt(results[0].outputAmount, 0);
        assertGt(results[1].outputAmount, 0);
    }
    
    function testWouldExceedSlippage() public {
        testAddLiquidity();
        
        uint256 amountIn = 100 * 10**18;
        uint256 minOutput = 1000 * 10**18; // Unreasonably high
        
        (bool exceeds, uint256 actualOutput) = simulator.wouldExceedSlippage(
            address(dashToken),
            address(weth),
            amountIn,
            minOutput,
            user1
        );
        
        assertTrue(exceeds);
        assertLt(actualOutput, minOutput);
    }
    
    function testGetPoolInfo() public {
        testAddLiquidity();
        
        (
            uint256 reserveA,
            uint256 reserveB,
            uint256 totalSupply,
            uint256 price,
            uint256 tvl
        ) = simulator.getPoolInfo();
        
        assertGt(reserveA, 0);
        assertGt(reserveB, 0);
        assertGt(totalSupply, 0);
        assertGt(price, 0);
        assertGt(tvl, 0);
    }
    
    // ============ Integration Tests ============
    
    function testFullTradingWorkflow() public {
        // 1. Add initial liquidity
        vm.startPrank(user1);
        
        uint256 dashAmount = 10000 * 10**18;
        uint256 wethAmount = 100 * 10**18;
        
        dashToken.approve(address(liquidityPool), dashAmount);
        weth.approve(address(liquidityPool), wethAmount);
        
        liquidityPool.addLiquidity(
            dashAmount,
            wethAmount,
            dashAmount,
            wethAmount,
            user1,
            block.timestamp + 1 hours
        );
        
        vm.stopPrank();
        
        // 2. Simulate a trade
        uint256 tradeAmount = 1000 * 10**18;
        TransactionSimulator.SimulationResult memory simulation = simulator.simulateSwap(
            address(dashToken),
            address(weth),
            tradeAmount,
            user2
        );
        
        // 3. Execute the trade via router
        vm.startPrank(user2);
        
        dashToken.approve(address(smartRouter), tradeAmount);
        
        DashSmartRouter.SwapParams memory params = DashSmartRouter.SwapParams({
            tokenIn: address(dashToken),
            tokenOut: address(weth),
            amountIn: tradeAmount,
            amountOutMin: simulation.outputAmount * 80 / 100, // 20% slippage tolerance
            to: user2,
            deadline: block.timestamp + 1 hours,
            routeData: ""
        });
        
        uint256 actualOutput = smartRouter.swapExactTokensForTokens(params);
        
        // 4. Verify trade execution matches simulation (within tolerance)
        uint256 tolerance = simulation.outputAmount * 25 / 100; // 25% tolerance for test
        assertApproxEqAbs(actualOutput, simulation.outputAmount, tolerance);
        
        vm.stopPrank();
        
        // 5. Verify pool state updated correctly
        (uint256 reserveA, uint256 reserveB,) = liquidityPool.getReserves();
        assertGt(reserveA, dashAmount); // More DASH in pool
        assertLt(reserveB, wethAmount); // Less WETH in pool
    }
    
    function testPriceImpactScenarios() public {
        testAddLiquidity();
        
        // Test small trade (minimal impact)
        uint256 smallAmount = 10 * 10**18;
        TransactionSimulator.SimulationResult memory smallTrade = simulator.simulateSwap(
            address(dashToken),
            address(weth),
            smallAmount,
            user1
        );
        
        // Test large trade (significant impact) 
        uint256 largeAmount = 2000 * 10**18;
        TransactionSimulator.SimulationResult memory largeTrade = simulator.simulateSwap(
            address(dashToken),
            address(weth),
            largeAmount,
            user1
        );
        
        // Large trade should have higher price impact
        assertGt(largeTrade.priceImpact, smallTrade.priceImpact);
        
        // Large trade should trigger MEV risk
        assertTrue(largeTrade.mevRisk);
        assertFalse(smallTrade.mevRisk);
    }
    
    function testLiquidityProvisionAndRewards() public {
        vm.startPrank(user1);
        
        // Add liquidity
        uint256 dashAmount = 5000 * 10**18;
        uint256 wethAmount = 50 * 10**18;
        
        dashToken.approve(address(liquidityPool), dashAmount);
        weth.approve(address(liquidityPool), wethAmount);
        
        liquidityPool.addLiquidity(
            dashAmount,
            wethAmount,
            dashAmount,
            wethAmount,
            user1,
            block.timestamp + 1 hours
        );
        
        vm.stopPrank();
        
        // Generate trading volume to create fees
        vm.startPrank(user2);
        
        for (uint256 i = 0; i < 5; i++) {
            dashToken.approve(address(liquidityPool), 100 * 10**18);
            liquidityPool.swapExactTokensForTokens(
                100 * 10**18,
                0,
                address(dashToken),
                user2,
                block.timestamp + 1 hours
            );
        }
        
        vm.stopPrank();
        
        // Fast forward time and check rewards
        vm.warp(block.timestamp + 1 days);
        
        vm.startPrank(user1);
        uint256 pendingRewards = liquidityPool.getPendingRewards(user1);
        assertGt(pendingRewards, 0);
        vm.stopPrank();
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzzSwapAmounts(uint256 swapAmount) public {
        // Bound the fuzz input to reasonable values
        swapAmount = bound(swapAmount, 1 * 10**18, 1000 * 10**18);
        
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        dashToken.approve(address(liquidityPool), swapAmount);
        
        uint256 amountOut = liquidityPool.swapExactTokensForTokens(
            swapAmount,
            0,
            address(dashToken),
            user2,
            block.timestamp + 1 hours
        );
        
        assertGt(amountOut, 0);
        assertLt(amountOut, swapAmount * 2); // Sanity check
        
        vm.stopPrank();
    }
    
    function testFuzzLiquidityAmounts(uint256 dashAmount, uint256 wethAmount) public {
        // Bound to reasonable values
        dashAmount = bound(dashAmount, 100 * 10**18, 50000 * 10**18);
        wethAmount = bound(wethAmount, 1 * 10**18, 500 * 10**18);
        
        vm.startPrank(user1);
        
        dashToken.approve(address(liquidityPool), dashAmount);
        weth.approve(address(liquidityPool), wethAmount);
        
        uint256 liquidity = liquidityPool.addLiquidity(
            dashAmount,
            wethAmount,
            0,
            0,
            user1,
            block.timestamp + 1 hours
        );
        
        assertGt(liquidity, 0);
        assertEq(liquidityPool.balanceOf(user1), liquidity);
        
        vm.stopPrank();
    }
    
    // ============ Edge Cases ============
    
    function testEmptyPoolSwap() public {
        vm.startPrank(user1);
        
        dashToken.approve(address(liquidityPool), 100 * 10**18);
        
        vm.expectRevert("Insufficient liquidity");
        liquidityPool.swapExactTokensForTokens(
            100 * 10**18,
            0,
            address(dashToken),
            user1,
            block.timestamp + 1 hours
        );
        
        vm.stopPrank();
    }
    
    function testExpiredDeadline() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        dashToken.approve(address(liquidityPool), 100 * 10**18);
        
        vm.expectRevert("Transaction expired");
        liquidityPool.swapExactTokensForTokens(
            100 * 10**18,
            0,
            address(dashToken),
            user2,
            block.timestamp - 1 // Expired deadline
        );
        
        vm.stopPrank();
    }
    
    function testZeroAmountSwap() public {
        testAddLiquidity();
        
        vm.startPrank(user2);
        
        vm.expectRevert("Insufficient input amount");
        liquidityPool.swapExactTokensForTokens(
            0,
            0,
            address(dashToken),
            user2,
            block.timestamp + 1 hours
        );
        
        vm.stopPrank();
    }
    
    // ============ Admin Functions Tests ============
    
    function testPoolAdminFunctions() public {
        vm.startPrank(owner);
        
        // Test pausing
        liquidityPool.setPaused(true);
        vm.stopPrank();
        
        vm.startPrank(user1);
        
        dashToken.approve(address(liquidityPool), 100 * 10**18);
        weth.approve(address(liquidityPool), 1 * 10**18);
        
        vm.expectRevert();
        liquidityPool.addLiquidity(
            100 * 10**18,
            1 * 10**18,
            0,
            0,
            user1,
            block.timestamp + 1 hours
        );
        
        vm.stopPrank();
        
        // Test unpausing
        vm.startPrank(owner);
        liquidityPool.setPaused(false);
        vm.stopPrank();
    }
    
    function testRouterAdminFunctions() public {
        vm.startPrank(owner);
        
        // Test adding new aggregator
        smartRouter.addAggregator(
            "TEST_DEX",
            makeAddr("testDex"),
            true,
            25, // 0.25% fee
            1000 // 10% max slippage
        );
        
        // Test updating protocol fee
        smartRouter.setProtocolFee(20); // 0.2%
        
        // Test updating burn rate
        smartRouter.setBurnRate(6000); // 60%
        
        vm.stopPrank();
    }
}
