// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../tokens/BasicERC20.sol";

/**
 * @title MinimalLiquidityPool
 * @dev Minimal AMM with constant product formula (x * y = k)
 * Simplified version inspired by Uniswap V2 core concepts
 */
contract MinimalLiquidityPool is BasicERC20 {
    BasicERC20 public immutable token0;
    BasicERC20 public immutable token1;
    
    uint256 public reserve0;  // Reserve of token0
    uint256 public reserve1;  // Reserve of token1
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event RemoveLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(address indexed trader, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out);
    
    constructor(address _token0, address _token1) BasicERC20(
        string(abi.encodePacked("LP-", BasicERC20(_token0).symbol(), "-", BasicERC20(_token1).symbol())),
        "LP",
        18,
        0
    ) {
        require(_token0 != _token1, "Identical tokens");
        require(_token0 != address(0) && _token1 != address(0), "Zero address");
        
        token0 = BasicERC20(_token0);
        token1 = BasicERC20(_token1);
    }
    
    /**
     * @dev Add liquidity to the pool
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 liquidity) {
        require(amount0Desired > 0 && amount1Desired > 0, "Invalid amounts");
        
        uint256 amount0;
        uint256 amount1;
        
        if (totalSupply == 0) {
            // First liquidity provision
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            
            // Lock minimum liquidity forever
            balanceOf[address(0)] = MINIMUM_LIQUIDITY;
            totalSupply = MINIMUM_LIQUIDITY;
            
        } else {
            // Calculate optimal amounts based on current ratio
            uint256 amount1Optimal = (amount0Desired * reserve1) / reserve0;
            
            if (amount1Optimal <= amount1Desired) {
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (amount1Desired * reserve0) / reserve1;
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }
            
            // Calculate liquidity tokens to mint
            liquidity = _min(
                (amount0 * totalSupply) / reserve0,
                (amount1 * totalSupply) / reserve1
            );
        }
        
        require(liquidity > 0, "Insufficient liquidity minted");
        
        // Transfer tokens from user
        require(token0.transferFrom(msg.sender, address(this), amount0), "Transfer failed");
        require(token1.transferFrom(msg.sender, address(this), amount1), "Transfer failed");
        
        // Mint LP tokens
        balanceOf[msg.sender] += liquidity;
        totalSupply += liquidity;
        
        // Update reserves
        reserve0 += amount0;
        reserve1 += amount1;
        
        emit Transfer(address(0), msg.sender, liquidity);
        emit AddLiquidity(msg.sender, amount0, amount1, liquidity);
    }
    
    /**
     * @dev Remove liquidity from the pool
     * @param liquidity Amount of LP tokens to burn
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function removeLiquidity(uint256 liquidity) external returns (uint256 amount0, uint256 amount1) {
        require(liquidity > 0, "Invalid liquidity");
        require(balanceOf[msg.sender] >= liquidity, "Insufficient LP tokens");
        
        // Calculate token amounts to return
        amount0 = (liquidity * reserve0) / totalSupply;
        amount1 = (liquidity * reserve1) / totalSupply;
        
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");
        
        // Burn LP tokens
        balanceOf[msg.sender] -= liquidity;
        totalSupply -= liquidity;
        
        // Transfer tokens to user
        require(token0.transfer(msg.sender, amount0), "Transfer failed");
        require(token1.transfer(msg.sender, amount1), "Transfer failed");
        
        // Update reserves
        reserve0 -= amount0;
        reserve1 -= amount1;
        
        emit Transfer(msg.sender, address(0), liquidity);
        emit RemoveLiquidity(msg.sender, amount0, amount1, liquidity);
    }
    
    /**
     * @dev Swap tokens using constant product formula
     * @param amount0In Amount of token0 to swap in (0 if swapping token1 for token0)
     * @param amount1In Amount of token1 to swap in (0 if swapping token0 for token1)
     * @param minAmountOut Minimum amount of tokens expected out
     */
    function swap(
        uint256 amount0In,
        uint256 amount1In,
        uint256 minAmountOut
    ) external {
        require(amount0In > 0 || amount1In > 0, "Invalid input amount");
        require(amount0In == 0 || amount1In == 0, "Only one input allowed");
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");
        
        uint256 amount0Out;
        uint256 amount1Out;
        
        if (amount0In > 0) {
            // Swapping token0 for token1
            // Apply 0.3% fee (997/1000)
            uint256 amount0InWithFee = amount0In * 997;
            amount1Out = (amount0InWithFee * reserve1) / (reserve0 * 1000 + amount0InWithFee);
            require(amount1Out >= minAmountOut, "Slippage exceeded");
            require(amount1Out < reserve1, "Insufficient output liquidity");
            
            // Transfer tokens
            require(token0.transferFrom(msg.sender, address(this), amount0In), "Transfer failed");
            require(token1.transfer(msg.sender, amount1Out), "Transfer failed");
            
            // Update reserves
            reserve0 += amount0In;
            reserve1 -= amount1Out;
            
        } else {
            // Swapping token1 for token0
            // Apply 0.3% fee (997/1000)
            uint256 amount1InWithFee = amount1In * 997;
            amount0Out = (amount1InWithFee * reserve0) / (reserve1 * 1000 + amount1InWithFee);
            require(amount0Out >= minAmountOut, "Slippage exceeded");
            require(amount0Out < reserve0, "Insufficient output liquidity");
            
            // Transfer tokens
            require(token1.transferFrom(msg.sender, address(this), amount1In), "Transfer failed");
            require(token0.transfer(msg.sender, amount0Out), "Transfer failed");
            
            // Update reserves
            reserve1 += amount1In;
            reserve0 -= amount0Out;
        }
        
        // Verify constant product formula (with fee adjustment)
        require(reserve0 * reserve1 >= (reserve0 - amount0Out + amount0In * 997 / 1000) * (reserve1 - amount1Out + amount1In * 997 / 1000), "K invariant");
        
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out);
    }
    
    /**
     * @dev Calculate output amount for a given input (for UI/preview)
     * @param amountIn Input amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Output amount
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) 
        external pure returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        require(reserveIn > 0 && reserveOut > 0, "Invalid reserves");
        
        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
    
    /**
     * @dev Get current reserves
     * @return _reserve0 Current reserve of token0
     * @return _reserve1 Current reserve of token1
     */
    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }
    
    // Internal helper functions
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
}
