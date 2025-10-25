# Minimal DEX MVP

A minimal decentralized exchange implementation with basic AMM functionality using the constant product formula (x * y = k).

## Overview

This MVP DEX provides the core functionality needed for a basic automated market maker:

- **Liquidity Pool Creation**: Create pools for any ERC20 token pair
- **Liquidity Provision**: Add/remove liquidity to earn fees
- **Token Swapping**: Swap between token pairs with automatic pricing
- **Fee Collection**: 0.3% trading fees distributed to liquidity providers

## Contracts

### Tokens
- **`BasicERC20.sol`**: Minimal ERC20 implementation without external dependencies
- **`DashTokenMVP.sol`**: DASH token (1B total supply)
- **`SmsToken.sol`**: SMS token (500M total supply)

### Pool
- **`MinimalLiquidityPool.sol`**: Core AMM with constant product formula

## Key Features

### 🔄 Constant Product Formula
Uses the proven `x * y = k` formula from Uniswap V2:
- Automatic price discovery based on supply/demand
- Price impact increases with trade size
- No external price oracles needed

### 💧 Liquidity Management
- **First Liquidity**: Sets initial price ratio
- **Subsequent Liquidity**: Must follow current pool ratio
- **LP Tokens**: Represent proportional ownership of the pool
- **Minimum Liquidity**: 1000 wei locked forever to prevent edge cases

### 💱 Trading
- **0.3% Fee**: Industry standard trading fee
- **Slippage Protection**: Minimum output amount enforcement
- **Price Impact**: Larger trades have higher price impact
- **MEV Resistance**: Simple but effective constant product pricing

## Mathematical Formulas

### Adding Liquidity
```solidity
// First liquidity provision
liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY

// Subsequent provisions
liquidity = min(
    (amount0 * totalSupply) / reserve0,
    (amount1 * totalSupply) / reserve1
)
```

### Swapping (with 0.3% fee)
```solidity
amountInWithFee = amountIn * 997
amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee)
```

### Removing Liquidity
```solidity
amount0 = (liquidity * reserve0) / totalSupply
amount1 = (liquidity * reserve1) / totalSupply
```

## Usage Examples

### Deploy and Setup
```bash
# Deploy contracts
forge script script/DeployMVPDEX.s.sol --rpc-url sepolia --broadcast --verify

# Run tests
forge test --match-path "test/mvp-dex/*" -v
```

### Add Liquidity
```solidity
// Approve tokens
dashToken.approve(address(pool), dashAmount);
smsToken.approve(address(pool), smsAmount);

// Add liquidity
uint256 liquidity = pool.addLiquidity(dashAmount, smsAmount);
```

### Swap Tokens
```solidity
// DASH -> SMS
dashToken.approve(address(pool), dashAmount);
pool.swap(dashAmount, 0, minSmsOut);

// SMS -> DASH  
smsToken.approve(address(pool), smsAmount);
pool.swap(0, smsAmount, minDashOut);
```

### Remove Liquidity
```solidity
// Remove liquidity
(uint256 amount0, uint256 amount1) = pool.removeLiquidity(liquidityAmount);
```

## Security Considerations

### ✅ Implemented Protections
- **Reentrancy**: Basic checks and external calls at end
- **Integer Overflow**: Solidity 0.8+ automatic protection
- **Zero Address**: Validation for token addresses
- **Slippage**: Minimum output enforcement
- **K Invariant**: Constant product formula verification

### ⚠️ Known Limitations (MVP)
- No advanced MEV protection
- No flashloan protection
- No pause mechanism
- No upgradability
- No governance
- Basic access control

## Testing

Comprehensive test suite covering:
- Pool creation and initialization
- First and subsequent liquidity additions
- Optimal and non-optimal ratios
- Token swapping in both directions
- Liquidity removal
- Edge cases and error conditions
- Gas usage optimization
- Complete workflow integration

```bash
# Run all MVP DEX tests
forge test --match-path "test/mvp-dex/*" -v

# Run specific test
forge test --match-test "testSwapDashForSms" -vvv
```

## Gas Usage

Approximate gas costs on Ethereum:
- **Add Liquidity**: ~211,000 gas
- **Swap**: ~120,000 gas
- **Remove Liquidity**: ~80,000 gas

## Deployment

The deployment script handles:
1. Deploy DASH and SMS tokens
2. Deploy DASH/SMS liquidity pool
3. Optionally add initial liquidity (testnet only)
4. Save deployment addresses to JSON
5. Provide verification commands

## Future Enhancements

This MVP can be extended with:
- Multi-pool factory pattern
- Router for optimal path finding
- Concentrated liquidity (Uniswap V3 style)
- Governance token and DAO
- Advanced MEV protection
- Flashloan functionality
- Integration with external DEX aggregators

## License

MIT License - see LICENSE file for details.
