// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@forge-std/Test.sol";
import "@forge-std/console.sol";
import "../src/tokens/DashToken.sol";
import "../src/tokens/TokenVesting.sol";

contract DashTokenTest is Test {
    DashToken public dashToken;
    TokenVesting public tokenVesting;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public minter = address(0x5);
    
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy DASH token
        dashToken = new DashToken(owner, treasury);
        
        // Deploy vesting contract
        tokenVesting = new TokenVesting(dashToken, owner);
        
        vm.stopPrank();
    }
    
    // ============ Basic Token Tests ============
    
    function testInitialState() public {
        assertEq(dashToken.name(), "Dash Protocol Token");
        assertEq(dashToken.symbol(), "DASH");
        assertEq(dashToken.decimals(), 18);
        assertEq(dashToken.totalSupply(), INITIAL_SUPPLY);
        assertEq(dashToken.balanceOf(treasury), INITIAL_SUPPLY);
        assertEq(dashToken.owner(), owner);
        assertTrue(dashToken.minters(owner));
    }
    
    function testMinting() public {
        vm.startPrank(owner);
        
        uint256 mintAmount = 1000 * 10**18;
        dashToken.mint(user1, mintAmount);
        
        assertEq(dashToken.balanceOf(user1), mintAmount);
        assertEq(dashToken.totalSupply(), INITIAL_SUPPLY + mintAmount);
        
        vm.stopPrank();
    }
    
    function testMintingRevertForNonMinter() public {
        vm.startPrank(user1);
        
        uint256 mintAmount = 1000 * 10**18;
        
        vm.expectRevert(DashToken.NotAuthorizedMinter.selector);
        dashToken.mint(user1, mintAmount);
        
        vm.stopPrank();
    }
    
    function testMinterManagement() public {
        vm.startPrank(owner);
        
        // Add minter
        dashToken.addMinter(minter);
        assertTrue(dashToken.minters(minter));
        
        // Test minting with new minter
        vm.stopPrank();
        vm.startPrank(minter);
        
        uint256 mintAmount = 1000 * 10**18;
        dashToken.mint(user1, mintAmount);
        assertEq(dashToken.balanceOf(user1), mintAmount);
        
        vm.stopPrank();
        vm.startPrank(owner);
        
        // Remove minter
        dashToken.removeMinter(minter);
        assertFalse(dashToken.minters(minter));
        
        vm.stopPrank();
    }
    
    // ============ Staking Tests ============
    
    function testStaking() public {
        // Give user1 some tokens
        vm.prank(treasury);
        dashToken.transfer(user1, 10000 * 10**18);
        
        vm.startPrank(user1);
        
        uint256 stakeAmount = 5000 * 10**18;
        dashToken.stake(stakeAmount);
        
        assertEq(dashToken.stakedBalance(user1), stakeAmount);
        assertEq(dashToken.totalStaked(), stakeAmount);
        assertEq(dashToken.balanceOf(user1), 5000 * 10**18); // Remaining balance
        
        vm.stopPrank();
    }
    
    function testStakingTiers() public {
        // Test different staking tiers
        vm.prank(treasury);
        dashToken.transfer(user1, 2_000_000 * 10**18);
        
        vm.startPrank(user1);
        
        // No tier
        assertEq(dashToken.getStakingTier(user1), 0);
        assertEq(dashToken.getFeeDiscount(user1), 0);
        
        // Bronze tier
        dashToken.stake(1000 * 10**18);
        assertEq(dashToken.getStakingTier(user1), 1);
        assertEq(dashToken.getFeeDiscount(user1), 500); // 5%
        
        // Silver tier  
        dashToken.stake(9000 * 10**18); // Total: 10K
        assertEq(dashToken.getStakingTier(user1), 2);
        assertEq(dashToken.getFeeDiscount(user1), 1000); // 10%
        
        // Gold tier
        dashToken.stake(90000 * 10**18); // Total: 100K
        assertEq(dashToken.getStakingTier(user1), 3);
        assertEq(dashToken.getFeeDiscount(user1), 2500); // 25%
        
        // Platinum tier
        dashToken.stake(900000 * 10**18); // Total: 1M
        assertEq(dashToken.getStakingTier(user1), 4);
        assertEq(dashToken.getFeeDiscount(user1), 5000); // 50%
        
        vm.stopPrank();
    }
    
    function testUnstaking() public {
        // Setup staking
        vm.prank(treasury);
        dashToken.transfer(user1, 10000 * 10**18);
        
        vm.startPrank(user1);
        dashToken.stake(5000 * 10**18);
        
        // Try to unstake immediately (should fail due to minimum staking period)
        vm.expectRevert(DashToken.StakingPeriodNotMet.selector);
        dashToken.unstake(1000 * 10**18);
        
        // Fast forward time beyond minimum staking period
        vm.warp(block.timestamp + 8 days);
        
        // Now unstaking should work
        uint256 unstakeAmount = 2000 * 10**18;
        dashToken.unstake(unstakeAmount);
        
        assertEq(dashToken.stakedBalance(user1), 3000 * 10**18);
        assertEq(dashToken.balanceOf(user1), 7000 * 10**18);
        
        vm.stopPrank();
    }
    
    // ============ Burning Tests ============
    
    function testBurning() public {
        vm.startPrank(treasury);
        
        uint256 burnAmount = 1000 * 10**18;
        uint256 initialSupply = dashToken.totalSupply();
        
        dashToken.burn(burnAmount);
        
        assertEq(dashToken.totalSupply(), initialSupply - burnAmount);
        assertEq(dashToken.balanceOf(treasury), INITIAL_SUPPLY - burnAmount);
        
        vm.stopPrank();
    }
    
    function testFeeBurning() public {
        // Transfer some tokens to the contract for fee burning
        vm.prank(treasury);
        dashToken.transfer(address(dashToken), 5000 * 10**18);
        
        vm.startPrank(owner);
        
        uint256 burnAmount = 1000 * 10**18;
        uint256 initialSupply = dashToken.totalSupply();
        
        dashToken.burnFees(burnAmount);
        
        assertEq(dashToken.totalSupply(), initialSupply - burnAmount);
        assertEq(dashToken.totalBurned(), burnAmount);
        
        vm.stopPrank();
    }
    
    // ============ Governance Tests ============
    
    function testPausingAndUnpausing() public {
        vm.startPrank(owner);
        
        // Pause the contract
        dashToken.pause();
        assertTrue(dashToken.paused());
        
        vm.stopPrank();
        
        // Try to transfer while paused (should fail)
        vm.prank(treasury);
        vm.expectRevert();
        dashToken.transfer(user1, 1000 * 10**18);
        
        vm.startPrank(owner);
        
        // Unpause the contract
        dashToken.unpause();
        assertFalse(dashToken.paused());
        
        vm.stopPrank();
        
        // Now transfer should work
        vm.prank(treasury);
        dashToken.transfer(user1, 1000 * 10**18);
        assertEq(dashToken.balanceOf(user1), 1000 * 10**18);
    }
    
    // Note: Snapshot functionality removed in OpenZeppelin v5
    // Test removed - can be re-added if custom snapshot implementation is needed
    
    // ============ Integration Tests ============
    
    function testFullWorkflow() public {
        console.log("Testing full DASH token workflow...");
        
        // 1. Initial state
        assertEq(dashToken.totalSupply(), INITIAL_SUPPLY);
        console.log("Initial supply:", dashToken.totalSupply() / 1e18, "DASH");
        
        // 2. Add treasury as minter and mint additional tokens
        vm.startPrank(owner);
        dashToken.addMinter(treasury);
        vm.stopPrank();
        
        vm.startPrank(treasury);
        dashToken.mint(treasury, 100_000_000 * 10**18);
        console.log("After minting:", dashToken.totalSupply() / 1e18, "DASH");
        
        // 3. Distribute tokens to users
        dashToken.transfer(user1, 50_000_000 * 10**18);
        dashToken.transfer(user2, 25_000_000 * 10**18);
        vm.stopPrank();
        
        // 4. Users stake tokens
        vm.startPrank(user1);
        dashToken.stake(10_000_000 * 10**18); // Gold tier
        console.log("User1 staking tier:", dashToken.getStakingTier(user1));
        console.log("User1 fee discount:", dashToken.getFeeDiscount(user1), "bps");
        vm.stopPrank();
        
        vm.startPrank(user2);
        dashToken.stake(1_000_000 * 10**18); // Platinum tier
        console.log("User2 staking tier:", dashToken.getStakingTier(user2));
        console.log("User2 fee discount:", dashToken.getFeeDiscount(user2), "bps");
        vm.stopPrank();
        
        // 5. Note: Snapshot functionality removed in OpenZeppelin v5
        console.log("Note: Snapshot functionality not available in v5");
        
        // 6. Burn some fees
        vm.startPrank(treasury);
        dashToken.transfer(address(dashToken), 1_000_000 * 10**18);
        vm.stopPrank();
        
        vm.startPrank(owner);
        dashToken.burnFees(500_000 * 10**18);
        console.log("Tokens burned:", dashToken.totalBurned() / 1e18, "DASH");
        console.log("Final supply:", dashToken.totalSupply() / 1e18, "DASH");
        vm.stopPrank();
        
        console.log("Full workflow test completed successfully!");
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzzStaking(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, 1_000_000 * 10**18);
        
        vm.prank(treasury);
        dashToken.transfer(user1, stakeAmount);
        
        vm.startPrank(user1);
        dashToken.stake(stakeAmount);
        
        assertEq(dashToken.stakedBalance(user1), stakeAmount);
        assertEq(dashToken.totalStaked(), stakeAmount);
        
        vm.stopPrank();
    }
    
    function testFuzzMinting(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1, dashToken.MAX_SUPPLY() - dashToken.totalSupply());
        
        uint256 initialSupply = dashToken.totalSupply();
        
        vm.prank(owner);
        dashToken.mint(user1, mintAmount);
        
        assertEq(dashToken.balanceOf(user1), mintAmount);
        assertEq(dashToken.totalSupply(), initialSupply + mintAmount);
    }
}
