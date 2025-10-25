// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/mvp-dex/tokens/DashTokenMVP.sol";
import "../src/mvp-dex/tokens/SmsToken.sol";
import "../src/mvp-dex/pool/MinimalLiquidityPool.sol";

/**
 * @title DeployMVPDEX
 * @dev Deployment script for Minimal DEX MVP
 */
contract DeployMVPDEX is Script {
    DashTokenMVP public dashToken;
    SmsToken public smsToken;
    MinimalLiquidityPool public pool;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying MVP DEX with deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy DASH token
        console.log("Deploying DASH token...");
        dashToken = new DashTokenMVP();
        console.log("DASH token deployed at:", address(dashToken));
        console.log("DASH total supply:", dashToken.totalSupply());
        
        // Deploy SMS token
        console.log("Deploying SMS token...");
        smsToken = new SmsToken();
        console.log("SMS token deployed at:", address(smsToken));
        console.log("SMS total supply:", smsToken.totalSupply());
        
        // Deploy liquidity pool
        console.log("Deploying DASH/SMS liquidity pool...");
        pool = new MinimalLiquidityPool(address(dashToken), address(smsToken));
        console.log("Liquidity pool deployed at:", address(pool));
        console.log("Pool LP token name:", pool.name());
        console.log("Pool LP token symbol:", pool.symbol());
        
        // Setup initial liquidity (optional - for testnet)
        if (block.chainid == 11155111) { // Sepolia
            console.log("Setting up initial liquidity on Sepolia...");
            
            uint256 dashAmount = 100_000 * 10**18;  // 100K DASH
            uint256 smsAmount = 50_000 * 10**18;    // 50K SMS
            
            // Approve pool to spend tokens
            dashToken.approve(address(pool), dashAmount);
            smsToken.approve(address(pool), smsAmount);
            
            // Add initial liquidity
            uint256 liquidity = pool.addLiquidity(dashAmount, smsAmount);
            console.log("Initial liquidity added:", liquidity);
            
            (uint256 reserve0, uint256 reserve1) = pool.getReserves();
            console.log("Pool reserves - DASH:", reserve0);
            console.log("Pool reserves - SMS:", reserve1);
        }
        
        vm.stopBroadcast();
        
        // Log deployment summary
        console.log("\n=== MVP DEX Deployment Summary ===");
        console.log("Network:", getChainName(block.chainid));
        console.log("DASH Token:", address(dashToken));
        console.log("SMS Token:", address(smsToken));
        console.log("DASH/SMS Pool:", address(pool));
        console.log("Deployer DASH balance:", dashToken.balanceOf(deployer));
        console.log("Deployer SMS balance:", smsToken.balanceOf(deployer));
        
        // Verify contracts (for testnets/mainnet)
        if (block.chainid != 31337) { // Not local/anvil
            console.log("To verify contracts, run:");
            console.log("DASH Token verification command:");
            console.log(string(abi.encodePacked("forge verify-contract ", vm.toString(address(dashToken)), " src/mvp-dex/tokens/DashTokenMVP.sol:DashTokenMVP --chain ", vm.toString(block.chainid))));
            console.log("SMS Token verification command:");
            console.log(string(abi.encodePacked("forge verify-contract ", vm.toString(address(smsToken)), " src/mvp-dex/tokens/SmsToken.sol:SmsToken --chain ", vm.toString(block.chainid))));
            console.log("Pool verification command:");
            console.log(string(abi.encodePacked("forge verify-contract ", vm.toString(address(pool)), " src/mvp-dex/pool/MinimalLiquidityPool.sol:MinimalLiquidityPool --chain ", vm.toString(block.chainid))));
        }
        
        // Save deployment addresses to file
        string memory deploymentInfo = string(abi.encodePacked(
            "{\n",
            '  "network": "', getChainName(block.chainid), '",\n',
            '  "chainId": ', vm.toString(block.chainid), ',\n',
            '  "dashToken": "', vm.toString(address(dashToken)), '",\n',
            '  "smsToken": "', vm.toString(address(smsToken)), '",\n',
            '  "pool": "', vm.toString(address(pool)), '",\n',
            '  "deployer": "', vm.toString(deployer), '"\n',
            "}"
        ));
        
        vm.writeFile("deployments/mvp-dex.json", deploymentInfo);
        console.log("Deployment info saved to deployments/mvp-dex.json");
    }
    
    function getChainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 1) return "mainnet";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 5) return "goerli";
        if (chainId == 137) return "polygon";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        if (chainId == 31337) return "anvil";
        return "unknown";
    }
}
