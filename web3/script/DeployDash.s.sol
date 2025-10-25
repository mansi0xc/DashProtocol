// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/DashToken.sol";
import "../src/TokenVesting.sol";

/**
 * @title DeployDash
 * @notice Deployment script for DASH token and vesting contracts
 * @dev Run with: forge script script/DeployDash.s.sol --rpc-url <rpc> --private-key <key> --broadcast
 */
contract DeployDash is Script {
    
    // ============ Deployment Parameters ============
    
    // Token allocation percentages (total 100%)
    uint256 constant TREASURY_ALLOCATION = 40; // 40% - 400M tokens
    uint256 constant TEAM_ALLOCATION = 20;     // 20% - 200M tokens
    uint256 constant ADVISORS_ALLOCATION = 5;  // 5%  - 50M tokens
    uint256 constant FOUNDATION_ALLOCATION = 15; // 15% - 150M tokens
    uint256 constant PUBLIC_SALE_ALLOCATION = 20; // 20% - 200M tokens
    
    // Vesting parameters
    uint256 constant TEAM_CLIFF = 365 days;      // 1 year cliff
    uint256 constant TEAM_DURATION = 4 * 365 days; // 4 year vest
    
    uint256 constant ADVISOR_CLIFF = 180 days;    // 6 month cliff
    uint256 constant ADVISOR_DURATION = 2 * 365 days; // 2 year vest
    
    uint256 constant FOUNDATION_CLIFF = 2 * 365 days; // 2 year cliff
    uint256 constant FOUNDATION_DURATION = 5 * 365 days; // 5 year vest
    
    // ============ State Variables ============
    
    DashToken public dashToken;
    TokenVesting public tokenVesting;
    
    address public deployer;
    address public treasury;
    address public teamMultisig;
    address public advisorWallet;
    address public foundation;
    
    // ============ Main Deployment Function ============
    
    function run() external {
        // Setup addresses
        deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        teamMultisig = vm.envOr("TEAM_MULTISIG_ADDRESS", deployer);
        advisorWallet = vm.envOr("ADVISOR_WALLET_ADDRESS", deployer);
        foundation = vm.envOr("FOUNDATION_ADDRESS", deployer);
        
        console.log("=== DASH Protocol Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Team Multisig:", teamMultisig);
        console.log("Advisor Wallet:", advisorWallet);
        console.log("Foundation:", foundation);
        console.log("");
        
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        
        // 1. Deploy DASH Token
        deployDashToken();
        
        // 2. Deploy Token Vesting Contract
        deployTokenVesting();
        
        // 3. Setup Token Allocations
        setupTokenAllocations();
        
        // 4. Setup Vesting Schedules
        setupVestingSchedules();
        
        // 5. Verify Deployment
        verifyDeployment();
        
        vm.stopBroadcast();
        
        logDeploymentSummary();
    }
    
    // ============ Deployment Functions ============
    
    function deployDashToken() internal {
        console.log("1. Deploying DASH Token...");
        
        dashToken = new DashToken(deployer, treasury);
        
        console.log("   DASH Token deployed at:", address(dashToken));
        console.log("   Initial supply:", dashToken.INITIAL_SUPPLY() / 1e18, "DASH");
        console.log("   Max supply:", dashToken.MAX_SUPPLY() / 1e18, "DASH");
        console.log("");
    }
    
    function deployTokenVesting() internal {
        console.log("2. Deploying Token Vesting Contract...");
        
        tokenVesting = new TokenVesting(dashToken, deployer);
        
        console.log("   Token Vesting deployed at:", address(tokenVesting));
        console.log("");
    }
    
    function setupTokenAllocations() internal {
        console.log("3. Setting up Token Allocations...");
        
        uint256 totalSupply = dashToken.INITIAL_SUPPLY();
        
        // Calculate allocation amounts
        uint256 teamAmount = (totalSupply * TEAM_ALLOCATION) / 100;
        uint256 advisorAmount = (totalSupply * ADVISORS_ALLOCATION) / 100;
        uint256 foundationAmount = (totalSupply * FOUNDATION_ALLOCATION) / 100;
        
        // Transfer tokens to vesting contract for team, advisors, and foundation
        uint256 vestingAmount = teamAmount + advisorAmount + foundationAmount;
        dashToken.transfer(address(tokenVesting), vestingAmount);
        
        console.log("   Transferred to vesting contract:", vestingAmount / 1e18, "DASH");
        console.log("   - Team allocation:", teamAmount / 1e18, "DASH");
        console.log("   - Advisor allocation:", advisorAmount / 1e18, "DASH");
        console.log("   - Foundation allocation:", foundationAmount / 1e18, "DASH");
        console.log("");
    }
    
    function setupVestingSchedules() internal {
        console.log("4. Setting up Vesting Schedules...");
        
        uint256 totalSupply = dashToken.INITIAL_SUPPLY();
        
        // Team vesting (1 year cliff, 4 year linear vest, revocable)
        uint256 teamAmount = (totalSupply * TEAM_ALLOCATION) / 100;
        tokenVesting.createVestingSchedule(
            teamMultisig,
            teamAmount,
            TEAM_CLIFF,
            TEAM_DURATION,
            true // revocable
        );
        console.log("   Team vesting schedule created");
        console.log("     Amount:", teamAmount / 1e18, "DASH");
        console.log("     Cliff:", TEAM_CLIFF / 86400, "days");
        console.log("     Duration:", TEAM_DURATION / 86400, "days");
        
        // Advisor vesting (6 month cliff, 2 year linear vest, revocable)
        uint256 advisorAmount = (totalSupply * ADVISORS_ALLOCATION) / 100;
        tokenVesting.createVestingSchedule(
            advisorWallet,
            advisorAmount,
            ADVISOR_CLIFF,
            ADVISOR_DURATION,
            true // revocable
        );
        console.log("   Advisor vesting schedule created");
        console.log("     Amount:", advisorAmount / 1e18, "DASH");
        console.log("     Cliff:", ADVISOR_CLIFF / 86400, "days");
        console.log("     Duration:", ADVISOR_DURATION / 86400, "days");
        
        // Foundation vesting (2 year cliff, 5 year linear vest, non-revocable)
        uint256 foundationAmount = (totalSupply * FOUNDATION_ALLOCATION) / 100;
        tokenVesting.createVestingSchedule(
            foundation,
            foundationAmount,
            FOUNDATION_CLIFF,
            FOUNDATION_DURATION,
            false // non-revocable
        );
        console.log("   Foundation vesting schedule created");
        console.log("     Amount:", foundationAmount / 1e18, "DASH");
        console.log("     Cliff:", FOUNDATION_CLIFF / 86400, "days");
        console.log("     Duration:", FOUNDATION_DURATION / 86400, "days");
        console.log("");
    }
    
    function verifyDeployment() internal view {
        console.log("5. Verifying Deployment...");
        
        // Verify DASH token
        require(dashToken.totalSupply() == dashToken.INITIAL_SUPPLY(), "Invalid total supply");
        require(dashToken.owner() == deployer, "Invalid token owner");
        require(dashToken.minters(deployer), "Deployer not set as minter");
        
        // Verify vesting contract
        require(address(tokenVesting.token()) == address(dashToken), "Invalid token in vesting");
        require(tokenVesting.owner() == deployer, "Invalid vesting owner");
        
        // Verify allocations
        require(tokenVesting.totalVestingCount(teamMultisig) == 1, "Team vesting not created");
        require(tokenVesting.totalVestingCount(advisorWallet) == 1, "Advisor vesting not created");
        require(tokenVesting.totalVestingCount(foundation) == 1, "Foundation vesting not created");
        
        console.log("   All verifications passed!");
        console.log("");
    }
    
    function logDeploymentSummary() internal view {
        console.log("=== Deployment Summary ===");
        console.log("DASH Token Address:", address(dashToken));
        console.log("Token Vesting Address:", address(tokenVesting));
        console.log("");
        
        console.log("Token Allocations:");
        console.log("- Treasury (liquid):", (dashToken.INITIAL_SUPPLY() * TREASURY_ALLOCATION) / 100 / 1e18, "DASH");
        console.log("- Team (vested):", (dashToken.INITIAL_SUPPLY() * TEAM_ALLOCATION) / 100 / 1e18, "DASH");
        console.log("- Advisors (vested):", (dashToken.INITIAL_SUPPLY() * ADVISORS_ALLOCATION) / 100 / 1e18, "DASH");
        console.log("- Foundation (vested):", (dashToken.INITIAL_SUPPLY() * FOUNDATION_ALLOCATION) / 100 / 1e18, "DASH");
        console.log("- Public Sale (liquid):", (dashToken.INITIAL_SUPPLY() * PUBLIC_SALE_ALLOCATION) / 100 / 1e18, "DASH");
        console.log("");
        
        console.log("Next Steps:");
        console.log("1. Verify contracts on Etherscan:");
        console.log("   forge verify-contract", address(dashToken), "src/DashToken.sol:DashToken --chain sepolia");
        console.log("   forge verify-contract", address(tokenVesting), "src/TokenVesting.sol:TokenVesting --chain sepolia");
        console.log("");
        console.log("2. Update frontend with contract addresses");
        console.log("3. Test basic functionality (mint, transfer, stake)");
        console.log("4. Deploy liquidity pools and router");
        console.log("");
        console.log("Deployment completed successfully!");
    }
}
