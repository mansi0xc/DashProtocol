// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/mvp-dex/tokens/DashTokenMVP.sol";
import "../../src/mvp-dex/tokens/SmsToken.sol";
import "../../src/mvp-dex/pool/MinimalLiquidityPool.sol";

contract MinimalDEXTest is Test {
    DashTokenMVP public dashToken;
    SmsToken public smsToken;
    MinimalLiquidityPool public pool;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    uint256 public constant INITIAL_DASH_BALANCE = 1_000_000 * 10**18; // 1M DASH
    uint256 public constant INITIAL_SMS_BALANCE = 500_000 * 10**18;    // 500K SMS
    
    function setUp() public {
        // Deploy tokens
        dashToken = new DashTokenMVP();
        smsToken = new SmsToken();
        
        // Deploy liquidity pool
        pool = new MinimalLiquidityPool(address(dashToken), address(smsToken));
        
        // Setup user balances
        dashToken.transfer(user1, INITIAL_DASH_BALANCE);
        dashToken.transfer(user2, INITIAL_DASH_BALANCE);
        smsToken.transfer(user1, INITIAL_SMS_BALANCE);
        smsToken.transfer(user2, INITIAL_SMS_BALANCE);
        
        // Approve pool to spend tokens
        vm.startPrank(user1);
        dashToken.approve(address(pool), type(uint256).max);
        smsToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        dashToken.approve(address(pool), type(uint256).max);
        smsToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }
    
    // Test pool creation and initial state
    function testPoolCreation() public view {
        assertEq(address(pool.token0()), address(dashToken));
        assertEq(address(pool.token1()), address(smsToken));
        assertEq(pool.totalSupply(), 0);
        
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
        
        // Check LP token name
        string memory expectedName = "LP-DASH-SMS";
        assertEq(pool.name(), expectedName);
        assertEq(pool.symbol(), "LP");
    }
    
    // Test first liquidity addition
    function testFirstLiquidityAddition() public {
        uint256 dashAmount = 100_000 * 10**18;  // 100K DASH
        uint256 smsAmount = 50_000 * 10**18;    // 50K SMS
        
        vm.startPrank(user1);
        
        uint256 balanceBefore = pool.balanceOf(user1);
        uint256 liquidity = pool.addLiquidity(dashAmount, smsAmount);
        uint256 balanceAfter = pool.balanceOf(user1);
        
        // Check LP tokens minted
        assertGt(liquidity, 0);
        assertEq(balanceAfter - balanceBefore, liquidity);
        
        // Check reserves updated
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        assertEq(reserve0, dashAmount);
        assertEq(reserve1, smsAmount);
        
        // Check total supply (includes minimum liquidity locked)
        assertEq(pool.totalSupply(), liquidity + pool.MINIMUM_LIQUIDITY());
        
        vm.stopPrank();
    }
    
    // Test subsequent liquidity addition (optimal ratio)
    function testSubsequentLiquidityAddition() public {
        // First, add initial liquidity
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        // Second user adds liquidity with optimal ratio
        uint256 dashAmount = 50_000 * 10**18;   // 50K DASH
        uint256 expectedSmsAmount = 25_000 * 10**18; // 25K SMS (2:1 ratio)
        
        vm.startPrank(user2);
        
        uint256 liquidityBefore = pool.balanceOf(user2);
        uint256 liquidity = pool.addLiquidity(dashAmount, expectedSmsAmount);
        uint256 liquidityAfter = pool.balanceOf(user2);
        
        assertGt(liquidity, 0);
        assertEq(liquidityAfter - liquidityBefore, liquidity);
        
        // Check reserves updated proportionally
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        assertEq(reserve0, 150_000 * 10**18);  // 100K + 50K
        assertEq(reserve1, 75_000 * 10**18);   // 50K + 25K
        
        vm.stopPrank();
    }
    
    // Test liquidity addition with non-optimal ratio
    function testNonOptimalLiquidityAddition() public {
        // Add initial liquidity (2:1 ratio)
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        // Try to add liquidity with different ratio
        vm.startPrank(user2);
        
        uint256 dashDesired = 60_000 * 10**18;  // 60K DASH
        uint256 smsDesired = 20_000 * 10**18;   // 20K SMS (3:1 ratio, different from pool's 2:1)
        
        uint256 liquidity = pool.addLiquidity(dashDesired, smsDesired);
        
        // Should use optimal amounts based on current ratio
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        
        // Pool should maintain its 2:1 ratio
        // With 20K SMS, optimal DASH would be 40K (2:1 ratio)
        assertEq(reserve0, 140_000 * 10**18); // 100K + 40K
        assertEq(reserve1, 70_000 * 10**18);  // 50K + 20K
        
        assertGt(liquidity, 0);
        
        vm.stopPrank();
    }
    
    // Test liquidity removal
    function testLiquidityRemoval() public {
        // Add initial liquidity
        vm.startPrank(user1);
        uint256 liquidityMinted = pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        
        uint256 dashBalanceBefore = dashToken.balanceOf(user1);
        uint256 smsBalanceBefore = smsToken.balanceOf(user1);
        
        // Remove half the liquidity
        uint256 liquidityToRemove = liquidityMinted / 2;
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(liquidityToRemove);
        
        uint256 dashBalanceAfter = dashToken.balanceOf(user1);
        uint256 smsBalanceAfter = smsToken.balanceOf(user1);
        
        // Check tokens returned
        assertEq(dashBalanceAfter - dashBalanceBefore, amount0);
        assertEq(smsBalanceAfter - smsBalanceBefore, amount1);
        
        // Should get approximately half the tokens back (allow for rounding)
        assertApproxEqAbs(amount0, 50_000 * 10**18, 1000); // ~50K DASH
        assertApproxEqAbs(amount1, 25_000 * 10**18, 1000); // ~25K SMS
        
        // Check LP tokens burned
        assertEq(pool.balanceOf(user1), liquidityMinted - liquidityToRemove);
        
        vm.stopPrank();
    }
    
    // Test token swap: DASH for SMS
    function testSwapDashForSms() public {
        // Add initial liquidity
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        // User2 swaps DASH for SMS
        vm.startPrank(user2);
        
        uint256 dashIn = 1_000 * 10**18;  // 1K DASH
        uint256 expectedSmsOut = pool.getAmountOut(dashIn, 100_000 * 10**18, 50_000 * 10**18);
        
        uint256 smsBalanceBefore = smsToken.balanceOf(user2);
        uint256 dashBalanceBefore = dashToken.balanceOf(user2);
        
        // Execute swap with 1% slippage tolerance
        uint256 minSmsOut = expectedSmsOut * 99 / 100;
        pool.swap(dashIn, 0, minSmsOut);
        
        uint256 smsBalanceAfter = smsToken.balanceOf(user2);
        uint256 dashBalanceAfter = dashToken.balanceOf(user2);
        
        // Check balances changed correctly
        assertEq(dashBalanceBefore - dashBalanceAfter, dashIn);
        assertGe(smsBalanceAfter - smsBalanceBefore, minSmsOut);
        
        // Verify we got expected amount (within small margin due to rounding)
        assertApproxEqAbs(smsBalanceAfter - smsBalanceBefore, expectedSmsOut, 1);
        
        vm.stopPrank();
    }
    
    // Test token swap: SMS for DASH
    function testSwapSmsForDash() public {
        // Add initial liquidity
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        // User2 swaps SMS for DASH
        vm.startPrank(user2);
        
        uint256 smsIn = 500 * 10**18;  // 500 SMS
        uint256 expectedDashOut = pool.getAmountOut(smsIn, 50_000 * 10**18, 100_000 * 10**18);
        
        uint256 smsBalanceBefore = smsToken.balanceOf(user2);
        uint256 dashBalanceBefore = dashToken.balanceOf(user2);
        
        // Execute swap with 1% slippage tolerance
        uint256 minDashOut = expectedDashOut * 99 / 100;
        pool.swap(0, smsIn, minDashOut);
        
        uint256 smsBalanceAfter = smsToken.balanceOf(user2);
        uint256 dashBalanceAfter = dashToken.balanceOf(user2);
        
        // Check balances changed correctly
        assertEq(smsBalanceBefore - smsBalanceAfter, smsIn);
        assertGe(dashBalanceAfter - dashBalanceBefore, minDashOut);
        
        // Verify we got expected amount
        assertApproxEqAbs(dashBalanceAfter - dashBalanceBefore, expectedDashOut, 1);
        
        vm.stopPrank();
    }
    
    // Test swap with insufficient slippage tolerance
    function testSwapSlippageExceeded() public {
        // Add initial liquidity
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        vm.startPrank(user2);
        
        uint256 dashIn = 1_000 * 10**18;
        uint256 expectedSmsOut = pool.getAmountOut(dashIn, 100_000 * 10**18, 50_000 * 10**18);
        
        // Set unrealistically high minimum output
        uint256 unrealisticMinOut = expectedSmsOut * 2;
        
        vm.expectRevert("Slippage exceeded");
        pool.swap(dashIn, 0, unrealisticMinOut);
        
        vm.stopPrank();
    }
    
    // Test swap with no liquidity
    function testSwapNoLiquidity() public {
        vm.startPrank(user2);
        
        vm.expectRevert("No liquidity");
        pool.swap(1_000 * 10**18, 0, 0);
        
        vm.stopPrank();
    }
    
    // Test edge case: invalid swap inputs
    function testInvalidSwapInputs() public {
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        vm.startPrank(user2);
        
        // Both inputs zero
        vm.expectRevert("Invalid input amount");
        pool.swap(0, 0, 0);
        
        // Both inputs non-zero
        vm.expectRevert("Only one input allowed");
        pool.swap(1_000 * 10**18, 500 * 10**18, 0);
        
        vm.stopPrank();
    }
    
    // Test getAmountOut calculation accuracy
    function testGetAmountOutCalculation() public view {
        uint256 amountIn = 1_000 * 10**18;
        uint256 reserveIn = 100_000 * 10**18;
        uint256 reserveOut = 50_000 * 10**18;
        
        uint256 amountOut = pool.getAmountOut(amountIn, reserveIn, reserveOut);
        
        // Manual calculation: (997 * 1000 * 50000) / (100000 * 1000 + 997 * 1000)
        uint256 expectedAmount = (997 * amountIn * reserveOut) / (reserveIn * 1000 + 997 * amountIn);
        
        assertEq(amountOut, expectedAmount);
    }
    
    // Test multiple swaps affect price
    function testMultipleSwapsAffectPrice() public {
        // Add initial liquidity
        vm.startPrank(user1);
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        vm.startPrank(user2);
        
        // First swap
        uint256 dashIn1 = 1_000 * 10**18;
        (uint256 reserve0_1, uint256 reserve1_1) = pool.getReserves();
        uint256 expectedOut1 = pool.getAmountOut(dashIn1, reserve0_1, reserve1_1);
        
        pool.swap(dashIn1, 0, 0);
        
        // Second swap (price should be worse due to reduced reserves)
        uint256 dashIn2 = 1_000 * 10**18;
        (uint256 reserve0_2, uint256 reserve1_2) = pool.getReserves();
        uint256 expectedOut2 = pool.getAmountOut(dashIn2, reserve0_2, reserve1_2);
        
        // Second swap should give less output due to price impact
        assertLt(expectedOut2, expectedOut1);
        
        vm.stopPrank();
    }
    
    // Test complete workflow: liquidity addition -> swaps -> liquidity removal
    function testCompleteWorkflow() public {
        // 1. Add initial liquidity
        vm.startPrank(user1);
        uint256 liquidity1 = pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        vm.stopPrank();
        
        // 2. Second user adds liquidity
        vm.startPrank(user2);
        uint256 liquidity2 = pool.addLiquidity(50_000 * 10**18, 25_000 * 10**18);
        vm.stopPrank();
        
        // 3. Perform several swaps
        vm.startPrank(user2);
        pool.swap(5_000 * 10**18, 0, 0);  // DASH -> SMS
        pool.swap(0, 1_000 * 10**18, 0);  // SMS -> DASH
        vm.stopPrank();
        
        // 4. Users remove their liquidity
        vm.startPrank(user1);
        pool.removeLiquidity(liquidity1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        pool.removeLiquidity(liquidity2);
        vm.stopPrank();
        
        // 5. Pool should be nearly empty (except minimum liquidity)
        (uint256 finalReserve0, uint256 finalReserve1) = pool.getReserves();
        assertLt(finalReserve0, 2000); // Very small amount left (allow for rounding)
        assertLt(finalReserve1, 2000);
        
        // Total supply should be close to minimum liquidity
        assertEq(pool.totalSupply(), pool.MINIMUM_LIQUIDITY());
    }
    
    // Gas optimization test
    function testGasUsage() public {
        // Test gas consumption of key operations
        vm.startPrank(user1);
        
        uint256 gasBefore = gasleft();
        pool.addLiquidity(100_000 * 10**18, 50_000 * 10**18);
        uint256 gasAddLiquidity = gasBefore - gasleft();
        
        gasBefore = gasleft();
        pool.swap(1_000 * 10**18, 0, 0);
        uint256 gasSwap = gasBefore - gasleft();
        
        // Log gas usage for reference
        emit log_named_uint("Gas for addLiquidity", gasAddLiquidity);
        emit log_named_uint("Gas for swap", gasSwap);
        
        // These are approximate bounds - actual values may vary
        assertLt(gasAddLiquidity, 250_000);
        assertLt(gasSwap, 180_000);
        
        vm.stopPrank();
    }
}
