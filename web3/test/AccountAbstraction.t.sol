// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@forge-std/Test.sol";
import "@forge-std/console.sol";
import "../src/DashToken.sol";
import "../src/DashAccount.sol";
import "../src/DashAccountFactory.sol";
import "../src/DashPaymaster.sol";
import "../lib/account-abstraction/contracts/core/EntryPoint.sol";

contract AccountAbstractionTest is Test {
    
    // ============ Contracts ============
    
    DashToken public dashToken;
    DashAccountFactory public accountFactory;
    DashPaymaster public paymaster;
    EntryPoint public entryPoint;
    
    // ============ Test Addresses ============
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public aiAgent = address(0x5);
    address public guardian1 = address(0x6);
    address public guardian2 = address(0x7);
    
    // ============ Test Keys ============
    
    uint256 public user1PrivateKey = 0x1111;
    uint256 public aiAgentPrivateKey = 0x2222;
    
    // ============ Setup ============
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy core contracts
        entryPoint = new EntryPoint();
        dashToken = new DashToken(owner, treasury);
        accountFactory = new DashAccountFactory(entryPoint, dashToken, owner);
        paymaster = new DashPaymaster(entryPoint, dashToken, treasury);
        
        // Fund paymaster with ETH for gas sponsorship
        vm.deal(address(paymaster), 100 ether);
        
        // Mint DASH tokens for testing
        dashToken.mint(user1, 2_000_000 * 10**18); // 2M DASH
        dashToken.mint(user2, 100_000 * 10**18);   // 100K DASH
        dashToken.mint(treasury, 10_000_000 * 10**18); // 10M DASH for paymaster
        
        vm.stopPrank();
    }
    
    // ============ Factory Tests ============
    
    function testAccountCreation() public {
        uint256 salt = accountFactory.generateSalt(user1, 0);
        address predictedAddress = accountFactory.getAddress(user1, salt);
        
        // Create account (caller must be the owner)
        vm.prank(user1);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Verify account was created correctly
        assertEq(address(account), predictedAddress);
        assertEq(account.owner(), user1);
        assertTrue(accountFactory.isAccount(address(account)));
        
        // Verify factory tracking
        address[] memory userAccounts = accountFactory.getUserAccounts(user1);
        assertEq(userAccounts.length, 1);
        assertEq(userAccounts[0], address(account));
    }
    
    function testDeterministicAddresses() public {
        uint256 salt1 = accountFactory.generateSalt(user1, 0);
        uint256 salt2 = accountFactory.generateSalt(user1, 1);
        
        address addr1 = accountFactory.previewAccountAddress(user1, 0);
        address addr2 = accountFactory.previewAccountAddress(user1, 1);
        
        // Different salts should produce different addresses
        assertTrue(addr1 != addr2);
        
        // Create accounts and verify addresses match predictions
        vm.startPrank(user1);
        DashAccount account1 = accountFactory.createAccount(user1, salt1);
        DashAccount account2 = accountFactory.createAccount(user1, salt2);
        vm.stopPrank();
        
        assertEq(address(account1), addr1);
        assertEq(address(account2), addr2);
    }
    
    function testBatchAccountCreation() public {
        address[] memory owners = new address[](3);
        uint256[] memory salts = new uint256[](3);
        
        owners[0] = user1;
        owners[1] = user2;
        owners[2] = aiAgent;
        
        salts[0] = 100;
        salts[1] = 200;
        salts[2] = 300;
        
        // For batch creation, we'll call from owner (factory owner)
        vm.prank(owner);
        DashAccount[] memory accounts = accountFactory.batchCreateAccounts(owners, salts);
        
        assertEq(accounts.length, 3);
        assertEq(accounts[0].owner(), user1);
        assertEq(accounts[1].owner(), user2);
        assertEq(accounts[2].owner(), aiAgent);
        
        // Verify factory stats
        (uint256 totalCreated,,,,) = accountFactory.getFactoryStats();
        assertGe(totalCreated, 3);
    }
    
    // ============ Account Tests ============
    
    function testAccountBasicExecution() public {
        // Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Fund account with ETH
        vm.deal(address(account), 1 ether);
        
        // Test basic execution (send ETH)
        address recipient = address(0x999);
        uint256 sendAmount = 0.1 ether;
        
        vm.prank(user1);
        account.execute(recipient, sendAmount, "");
        
        assertEq(recipient.balance, sendAmount);
        assertEq(address(account).balance, 1 ether - sendAmount);
    }
    
    function testSessionKeyCreation() public {
        // Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Define session key parameters
        uint256 spendingLimit = 1 ether;
        uint256 duration = 1 days;
        address[] memory allowedTargets = new address[](1);
        allowedTargets[0] = address(dashToken);
        bytes4[] memory allowedSelectors = new bytes4[](1);
        allowedSelectors[0] = dashToken.transfer.selector;
        
        // Create session key
        vm.prank(user1);
        bytes32 sessionId = account.createSessionKey(
            aiAgent,
            spendingLimit,
            duration,
            allowedTargets,
            allowedSelectors
        );
        
        // Verify session key was created
        DashAccount.SessionKey memory session = account.getSessionKey(sessionId);
        assertEq(session.signer, aiAgent);
        assertEq(session.spendingLimit, spendingLimit);
        assertTrue(session.isActive);
        assertEq(session.allowedTargets.length, 1);
        assertEq(session.allowedTargets[0], address(dashToken));
    }
    
    function testSessionKeyRevocation() public {
        // Create account and session key
        uint256 salt = accountFactory.generateSalt(user1, 0);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        address[] memory allowedTargets = new address[](1);
        allowedTargets[0] = address(dashToken);
        bytes4[] memory allowedSelectors = new bytes4[](1);
        allowedSelectors[0] = dashToken.transfer.selector;
        
        vm.prank(user1);
        bytes32 sessionId = account.createSessionKey(
            aiAgent,
            1 ether,
            1 days,
            allowedTargets,
            allowedSelectors
        );
        
        // Verify active
        assertTrue(account.getSessionKey(sessionId).isActive);
        
        // Revoke session key
        vm.prank(user1);
        account.revokeSessionKey(sessionId);
        
        // Verify revoked
        assertFalse(account.getSessionKey(sessionId).isActive);
    }
    
    function testSpendingLimits() public {
        // Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Fund account with more than daily limit
        vm.deal(address(account), 20 ether);
        
        // Try to spend more than daily limit (should fail)
        vm.prank(user1);
        vm.expectRevert(DashAccount.DailyLimitExceeded.selector);
        account.execute(address(0x999), 15 ether, "");
    }
    
    function testBatchExecution() public {
        // Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Fund account
        vm.deal(address(account), 5 ether);
        
        // Prepare batch transactions
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        
        targets[0] = address(0x111);
        targets[1] = address(0x222);
        values[0] = 0.1 ether;
        values[1] = 0.2 ether;
        calldatas[0] = "";
        calldatas[1] = "";
        
        // Execute batch
        vm.prank(user1);
        account.executeBatchTransactions(targets, values, calldatas);
        
        // Verify transfers
        assertEq(address(0x111).balance, 0.1 ether);
        assertEq(address(0x222).balance, 0.2 ether);
    }
    
    function testSocialRecovery() public {
        // Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Initialize recovery with guardians
        address[] memory guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        
        vm.prank(user1);
        account.initializeRecovery(guardians, 2); // Require both guardians
        
        // Verify recovery config
        (,,,uint256 guardianCount, uint256 threshold,) = account.getSecurityInfo();
        assertEq(guardianCount, 2);
        assertEq(threshold, 2);
    }
    
    // ============ Paymaster Tests ============
    
    function testPaymasterSponsorshipTiers() public {
        // Check Bronze tier (1K DASH staked)
        vm.startPrank(user2);
        dashToken.stake(1000 * 10**18); // Bronze tier
        
        (uint8 tier, uint256 dailyLimit, uint256 dailyUsed,uint256 transactionLimit, uint256 totalSponsored, bool isBlacklisted2) = paymaster.getUserSponsorshipInfo(user2);
        assertEq(tier, 1); // Bronze
        assertGt(dailyLimit, 0);
        assertEq(dailyUsed, 0);
        
        vm.stopPrank();
    }
    
    function testPaymasterDashPayment() public {
        uint256 gasCost = 0.01 ether;
        uint256 dashRequired = paymaster.calculateDashPayment(gasCost);
        
        assertGt(dashRequired, 0);
        console.log("DASH required for 0.01 ETH gas:", dashRequired / 1e18, "DASH");
    }
    
    function testPaymasterGlobalLimits() public {
        // Get initial stats
        (,, uint256 dailyGlobalLimit,,,) = paymaster.getPaymasterStats();
        assertGt(dailyGlobalLimit, 0);
        
        // Test setting new limit (only owner can do this)
        vm.prank(owner);
        paymaster.setDailyGlobalLimit(50 ether);
        
        (,, uint256 newLimit,,,) = paymaster.getPaymasterStats();
        assertEq(newLimit, 50 ether);
    }
    
    function testPaymasterBlacklisting() public {
        // Owner blacklists a user
        vm.prank(owner);
        paymaster.setUserBlacklisted(user1, true);
        
        // Check user is blacklisted
        (,,,,,bool isBlacklistedCheck) = paymaster.getUserSponsorshipInfo(user1);
        assertTrue(isBlacklistedCheck);
        
        // Un-blacklist
        vm.prank(owner);
        paymaster.setUserBlacklisted(user1, false);
        
        (,,,,,isBlacklistedCheck) = paymaster.getUserSponsorshipInfo(user1);
        assertFalse(isBlacklistedCheck);
    }
    
    function testPaymasterPausing() public {
        // Owner can pause
        vm.prank(owner);
        paymaster.setPaused(true);
        
        (,,,,,bool paused) = paymaster.getPaymasterStats();
        assertTrue(paused);
        
        // Owner can unpause
        vm.prank(owner);
        paymaster.setPaused(false);
        
        (,,,,,paused) = paymaster.getPaymasterStats();
        assertFalse(paused);
    }
    
    // ============ Integration Tests ============
    
    function testFullAAWorkflow() public {
        console.log("Testing full Account Abstraction workflow...");
        
        // 1. Create account
        uint256 salt = accountFactory.generateSalt(user1, 0);
        DashAccount account = accountFactory.createAccount(user1, salt);
        console.log("Account created:", address(account));
        
        // 2. User stakes DASH for sponsorship tier
        vm.startPrank(user1);
        dashToken.stake(10_000 * 10**18); // Silver tier
        vm.stopPrank();
        
        uint8 tier = dashToken.getStakingTier(user1);
        console.log("User staking tier:", tier);
        
        // 3. Create session key for AI agent
        address[] memory allowedTargets = new address[](2);
        allowedTargets[0] = address(dashToken);
        allowedTargets[1] = address(account);
        
        bytes4[] memory allowedSelectors = new bytes4[](2);
        allowedSelectors[0] = dashToken.transfer.selector;
        allowedSelectors[1] = account.executeBatchTransactions.selector;
        
        vm.prank(user1);
        bytes32 sessionId = account.createSessionKey(
            aiAgent,
            1 ether,
            7 days,
            allowedTargets,
            allowedSelectors
        );
        console.log("Session key created for AI agent");
        
        // 4. Test basic account functionality
        vm.deal(address(account), 2 ether);
        
        vm.prank(user1);
        account.execute(treasury, 0.1 ether, "");
        
        assertEq(treasury.balance, 0.1 ether);
        console.log("Basic execution successful");
        
        // 5. Test spending limits
        (uint256 dailyLimit, uint256 dailySpent,,,,) = account.getSecurityInfo();
        console.log("Daily spending limit:", dailyLimit / 1e18, "ETH");
        console.log("Daily spent so far:", dailySpent / 1e18, "ETH");
        
        // 6. Test paymaster sponsorship eligibility  
        bool isBlacklisted;
        (tier,,,,, isBlacklisted) = paymaster.getUserSponsorshipInfo(user1);
        console.log("Paymaster tier:", tier);
        console.log("Is blacklisted:", isBlacklisted);
        
        // 7. Verify DASH fee discount
        uint256 discount = account.getDashFeeDiscount();
        console.log("DASH fee discount:", discount, "bps");
        
        console.log("Full AA workflow completed successfully!");
    }
    
    // ============ Gas Tests ============
    
    function testGasOptimization() public {
        // Test account creation gas cost
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, 123);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Account creation gas:", gasUsed);
        assertLt(gasUsed, 300000); // Should be under 300k gas
        
        // Test session key creation gas
        gasBefore = gasleft();
        
        address[] memory targets = new address[](1);
        targets[0] = address(dashToken);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = dashToken.transfer.selector;
        
        vm.prank(user1);
        account.createSessionKey(aiAgent, 1 ether, 1 days, targets, selectors);
        
        gasUsed = gasBefore - gasleft();
        console.log("Session key creation gas:", gasUsed);
        assertLt(gasUsed, 150000); // Should be under 150k gas
    }
    
    // ============ Security Tests ============
    
    function testUnauthorizedAccess() public {
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Non-owner cannot create session keys
        address[] memory targets = new address[](1);
        targets[0] = address(dashToken);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = dashToken.transfer.selector;
        
        vm.prank(user2);
        vm.expectRevert();
        account.createSessionKey(aiAgent, 1 ether, 1 days, targets, selectors);
        
        // Non-owner cannot execute transactions
        vm.prank(user2);
        vm.expectRevert();
        account.execute(address(0x999), 0.1 ether, "");
    }
    
    function testSessionKeyLimits() public {
        uint256 salt = accountFactory.generateSalt(user1, 0);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        // Try to create session key with spending limit too high
        address[] memory targets = new address[](1);
        targets[0] = address(dashToken);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = dashToken.transfer.selector;
        
        vm.prank(user1);
        vm.expectRevert();
        account.createSessionKey(
            aiAgent, 
            2000 ether, // Exceeds MAX_SESSION_SPENDING
            1 days, 
            targets, 
            selectors
        );
    }
    
    // ============ Edge Case Tests ============
    
    function testZeroAddressInputs() public {
        // Cannot create account for zero address
        vm.prank(owner);
        vm.expectRevert();
        accountFactory.createAccount(address(0), 123);
        
        // Cannot create session key for zero signer
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        address[] memory targets = new address[](1);
        targets[0] = address(dashToken);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = dashToken.transfer.selector;
        
        vm.prank(user1);
        vm.expectRevert();
        account.createSessionKey(address(0), 1 ether, 1 days, targets, selectors);
    }
    
    function testArrayLengthMismatch() public {
        uint256 salt = accountFactory.generateSalt(user1, 0);
        vm.prank(owner);
        DashAccount account = accountFactory.createAccount(user1, salt);
        
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1); // Mismatched length
        bytes[] memory calldatas = new bytes[](2);
        
        vm.prank(user1);
        vm.expectRevert();
        account.executeBatchTransactions(targets, values, calldatas);
    }
}
