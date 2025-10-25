// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../tokens/DashToken.sol";

/**
 * @title GenericLiquidityPool
 * @notice UniswapV2-compatible AMM for any ERC20 token pair
 * @dev Implements constant product formula (x * y = k) with advanced features:
 *      - TWAP price oracles
 *      - Fee discounts for DASH token holders
 *      - LP token incentives
 *      - MEV protection
 *      - Flash loan support
 */
contract GenericLiquidityPool is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // ============ Constants ============
    
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant BASE_FEE = 30; // 0.3% like Uniswap
    uint256 public constant TWAP_PERIOD = 30 minutes;
    
    // ============ Immutable State ============
    
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    DashToken public immutable dashToken;
    address public immutable factory;
    
    // ============ Pool State ============
    
    struct Reserve {
        uint112 reserve0;           // Reserve of token0
        uint112 reserve1;           // Reserve of token1
        uint32 blockTimestampLast;  // Last update timestamp
    }
    
    struct TWAPData {
        uint256 price0CumulativeLast; // Cumulative price of token0
        uint256 price1CumulativeLast; // Cumulative price of token1
        uint256 kLast;               // Last K value
    }
    
    Reserve public reserves;
    TWAPData public twapData;
    
    // Fee management
    uint256 public protocolFee = 1600; // 16% of trading fees (0.048% of trade)
    address public feeCollector;
    
    // Flash loan fees
    uint256 public flashLoanFee = 3; // 0.03%
    
    // LP rewards
    mapping(address => uint256) public lastRewardTime;
    mapping(address => uint256) public pendingRewards;
    uint256 public rewardRate = 100 * 1e18; // Base reward rate
    uint256 public totalRewardsDistributed;
    
    // Security
    uint256 public maxSwapImpact = 1000; // 10% max price impact per swap
    bool public flashLoansEnabled = true;
    
    // ============ Events ============
    
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);
    
    // ============ Errors ============
    
    error InsufficientLiquidity();
    error InsufficientAmount();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InvalidTo();
    error Overflow();
    error K();
    error ExcessivePriceImpact();
    error FlashLoansDisabled();
    error InvalidCallback();
    
    // ============ Modifiers ============
    
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _token0,
        address _token1,
        address _dashToken,
        address _feeCollector,
        address initialOwner
    ) ERC20(
        "Dash DEX LP Token",
        "DDEX-LP"
    ) Ownable(initialOwner) {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        dashToken = DashToken(_dashToken);
        factory = msg.sender;
        feeCollector = _feeCollector;
        
        reserves.blockTimestampLast = uint32(block.timestamp);
    }
    
    // ============ UniswapV2 Compatible Interface ============
    
    /**
     * @notice Get current reserves and last update time
     * @return _reserve0 Reserve of token0
     * @return _reserve1 Reserve of token1  
     * @return _blockTimestampLast Last update timestamp
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserves.reserve0;
        _reserve1 = reserves.reserve1;
        _blockTimestampLast = reserves.blockTimestampLast;
    }
    
    /**
     * @notice Mint liquidity tokens
     * @param to Address to receive LP tokens
     * @return liquidity Amount of LP tokens minted
     */
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;
        
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }
        
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        
        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);
        
        if (feeOn) twapData.kLast = uint256(reserves.reserve0) * reserves.reserve1;
        
        // Update rewards
        _updateRewards(to);
        
        emit Mint(msg.sender, amount0, amount1);
    }
    
    /**
     * @notice Burn liquidity tokens
     * @param to Address to receive underlying tokens
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        IERC20 _token0 = token0;
        IERC20 _token1 = token1;
        uint256 balance0 = _token0.balanceOf(address(this));
        uint256 balance1 = _token1.balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        
        _burn(address(this), liquidity);
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);
        
        balance0 = _token0.balanceOf(address(this));
        balance1 = _token1.balanceOf(address(this));
        
        _update(balance0, balance1, _reserve0, _reserve1);
        
        if (feeOn) twapData.kLast = uint256(reserves.reserve0) * reserves.reserve1;
        
        emit Burn(msg.sender, amount0, amount1, to);
    }
    
    /**
     * @notice Swap tokens
     * @param amount0Out Amount of token0 to receive
     * @param amount1Out Amount of token1 to receive
     * @param to Address to receive output tokens
     * @param data Calldata for flash loans
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) 
        external 
        nonReentrant 
        whenNotPaused
    {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();
        
        uint256 balance0;
        uint256 balance1;
        {
            IERC20 _token0 = token0;
            IERC20 _token1 = token1;
            if (to == address(_token0) || to == address(_token1)) revert InvalidTo();
            
            if (amount0Out > 0) _token0.safeTransfer(to, amount0Out);
            if (amount1Out > 0) _token1.safeTransfer(to, amount1Out);
            
            // Flash loan callback
            if (data.length > 0) {
                if (!flashLoansEnabled) revert FlashLoansDisabled();
                IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            }
            
            balance0 = _token0.balanceOf(address(this));
            balance1 = _token1.balanceOf(address(this));
        }
        
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
        
        // Fee calculation with DASH discount
        uint256 fee0 = _calculateFeeWithDiscount(amount0In, msg.sender);
        uint256 fee1 = _calculateFeeWithDiscount(amount1In, msg.sender);
        
        {
            uint256 balance0Adjusted = (balance0 * 1000) - fee0;
            uint256 balance1Adjusted = (balance1 * 1000) - fee1;
            if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * _reserve1 * (1000**2)) revert K();
        }
        
        // Check price impact
        _checkPriceImpact(_reserve0, _reserve1, balance0, balance1);
        
        _update(balance0, balance1, _reserve0, _reserve1);
        
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
    
    // ============ Enhanced Features ============
    
    /**
     * @notice Add liquidity with automatic optimal ratios
     * @param token0Amount Desired amount of token0
     * @param token1Amount Desired amount of token1
     * @param token0AmountMin Minimum token0 amount
     * @param token1AmountMin Minimum token1 amount
     * @param to LP token recipient
     * @param deadline Transaction deadline
     */
    function addLiquidity(
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 token0AmountMin,
        uint256 token1AmountMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _calculateOptimalAmounts(token0Amount, token1Amount, token0AmountMin, token1AmountMin);
        
        token0.safeTransferFrom(msg.sender, address(this), amountA);
        token1.safeTransferFrom(msg.sender, address(this), amountB);
        
        liquidity = this.mint(to);
    }
    
    /**
     * @notice Remove liquidity
     */
    function removeLiquidity(
        uint256 liquidity,
        uint256 token0AmountMin,
        uint256 token1AmountMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amount0, uint256 amount1) {
        _transfer(msg.sender, address(this), liquidity);
        (amount0, amount1) = this.burn(to);
        
        require(amount0 >= token0AmountMin, "INSUFFICIENT_A_AMOUNT");
        require(amount1 >= token1AmountMin, "INSUFFICIENT_B_AMOUNT");
    }
    
    /**
     * @notice Swap exact tokens for tokens
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address to,
        uint256 deadline
    ) external ensure(deadline) nonReentrant returns (uint256 amountOut) {
        bool isToken0Input = tokenIn == address(token0);
        require(isToken0Input || tokenIn == address(token1), "INVALID_TOKEN");
        
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        if (isToken0Input) {
            amountOut = getAmountOut(amountIn, reserves.reserve0, reserves.reserve1, msg.sender);
            require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
            this.swap(0, amountOut, to, new bytes(0));
        } else {
            amountOut = getAmountOut(amountIn, reserves.reserve1, reserves.reserve0, msg.sender);
            require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
            this.swap(amountOut, 0, to, new bytes(0));
        }
    }
    
    /**
     * @notice Flash loan function
     * @param recipient Loan recipient
     * @param amount0 Amount of token0 to borrow
     * @param amount1 Amount of token1 to borrow
     * @param data Callback data
     */
    function flashLoan(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external nonReentrant {
        if (!flashLoansEnabled) revert FlashLoansDisabled();
        
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        
        uint256 fee0 = (amount0 * flashLoanFee) / FEE_DENOMINATOR;
        uint256 fee1 = (amount1 * flashLoanFee) / FEE_DENOMINATOR;
        
        if (amount0 > 0) token0.safeTransfer(recipient, amount0);
        if (amount1 > 0) token1.safeTransfer(recipient, amount1);
        
        // Callback
        IFlashLoanRecipient(recipient).receiveFlashLoan(amount0, amount1, fee0, fee1, data);
        
        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));
        
        require(balance0After >= balance0Before + fee0, "INSUFFICIENT_FLASH_LOAN_REPAYMENT_0");
        require(balance1After >= balance1Before + fee1, "INSUFFICIENT_FLASH_LOAN_REPAYMENT_1");
        
        emit FlashLoan(recipient, amount0 + amount1, fee0 + fee1);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Calculate output amount for given input
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, address trader) 
        public 
        view 
        returns (uint256 amountOut) 
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        
        uint256 fee = _calculateFeeWithDiscount(amountIn, trader);
        uint256 amountInWithFee = (amountIn * 1000) - fee;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    /**
     * @notice Calculate input amount for given output
     */
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, address trader)
        public
        view
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > amountOut, "INSUFFICIENT_LIQUIDITY");
        
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * (1000 - _getFeeRate(trader));
        amountIn = (numerator / denominator) + 1;
    }
    
    /**
     * @notice Get current price (token1 per token0)
     */
    function getPrice() external view returns (uint256 price) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (_reserve0 == 0) return 0;
        price = (uint256(_reserve1) * PRECISION) / uint256(_reserve0);
    }
    
    /**
     * @notice Get TWAP price over period
     */
    function getTWAPPrice(uint256 period) external view returns (uint256 price0Average, uint256 price1Average) {
        require(period <= TWAP_PERIOD, "PERIOD_TOO_LONG");
        
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint256 timeElapsed = uint256(blockTimestamp - reserves.blockTimestampLast);
        
        if (timeElapsed == 0) {
            (uint112 _reserve0, uint112 _reserve1,) = getReserves();
            if (_reserve0 > 0 && _reserve1 > 0) {
                price0Average = (uint256(_reserve1) * PRECISION) / uint256(_reserve0);
                price1Average = (uint256(_reserve0) * PRECISION) / uint256(_reserve1);
            }
        } else {
            price0Average = twapData.price0CumulativeLast / timeElapsed;
            price1Average = twapData.price1CumulativeLast / timeElapsed;
        }
    }
    
    // ============ Internal Functions ============
    
    function _calculateOptimalAmounts(
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 token0AmountMin,
        uint256 token1AmountMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        
        if (_reserve0 == 0 && _reserve1 == 0) {
            return (token0Amount, token1Amount);
        }
        
        uint256 token1Optimal = (token0Amount * _reserve1) / _reserve0;
        if (token1Optimal <= token1Amount) {
            require(token1Optimal >= token1AmountMin, "INSUFFICIENT_B_AMOUNT");
            return (token0Amount, token1Optimal);
        } else {
            uint256 token0Optimal = (token1Amount * _reserve0) / _reserve1;
            require(token0Optimal <= token0Amount && token0Optimal >= token0AmountMin, "INSUFFICIENT_A_AMOUNT");
            return (token0Optimal, token1Amount);
        }
    }
    
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = twapData.kLast;
        
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            twapData.kLast = 0;
        }
    }
    
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint256 timeElapsed = uint256(blockTimestamp - reserves.blockTimestampLast);
        
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            twapData.price0CumulativeLast += uint256(_reserve1) * timeElapsed / _reserve0;
            twapData.price1CumulativeLast += uint256(_reserve0) * timeElapsed / _reserve1;
        }
        
        reserves.reserve0 = uint112(balance0);
        reserves.reserve1 = uint112(balance1);
        reserves.blockTimestampLast = blockTimestamp;
        
        emit Sync(uint112(balance0), uint112(balance1));
    }
    
    function _calculateFeeWithDiscount(uint256 amount, address trader) internal view returns (uint256) {
        uint256 feeRate = _getFeeRate(trader);
        return (amount * feeRate) / 1000;
    }
    
    function _getFeeRate(address trader) internal view returns (uint256) {
        // Get DASH staking discount
        uint256 discount = dashToken.getFeeDiscount(trader);
        uint256 effectiveFee = BASE_FEE;
        
        if (discount > 0) {
            effectiveFee = (BASE_FEE * (FEE_DENOMINATOR - discount)) / FEE_DENOMINATOR;
        }
        
        return effectiveFee;
    }
    
    function _checkPriceImpact(uint112 _reserve0, uint112 _reserve1, uint256 balance0, uint256 balance1) internal view {
        uint256 oldPrice = (uint256(_reserve1) * PRECISION) / uint256(_reserve0);
        uint256 newPrice = (balance1 * PRECISION) / balance0;
        
        uint256 priceImpact;
        if (newPrice > oldPrice) {
            priceImpact = ((newPrice - oldPrice) * FEE_DENOMINATOR) / oldPrice;
        } else {
            priceImpact = ((oldPrice - newPrice) * FEE_DENOMINATOR) / oldPrice;
        }
        
        if (priceImpact > maxSwapImpact) revert ExcessivePriceImpact();
    }
    
    function _updateRewards(address user) internal {
        if (balanceOf(user) > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime[user];
            uint256 userLP = balanceOf(user);
            uint256 totalLP = totalSupply();
            
            if (totalLP > 0 && timeElapsed > 0) {
                uint256 newRewards = (timeElapsed * rewardRate * userLP) / (86400 * totalLP);
                pendingRewards[user] += newRewards;
            }
        }
        lastRewardTime[user] = block.timestamp;
    }
    
    // ============ Admin Functions ============
    
    function setProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= 2500, "FEE_TOO_HIGH"); // Max 25%
        protocolFee = newFee;
    }
    
    function setFlashLoanFee(uint256 newFee) external onlyOwner {
        require(newFee <= 100, "FEE_TOO_HIGH"); // Max 1%
        flashLoanFee = newFee;
    }
    
    function setMaxSwapImpact(uint256 newImpact) external onlyOwner {
        require(newImpact >= 100 && newImpact <= 5000, "INVALID_IMPACT"); // 1% to 50%
        maxSwapImpact = newImpact;
    }
    
    function setFlashLoansEnabled(bool enabled) external onlyOwner {
        flashLoansEnabled = enabled;
    }
    
    function setPaused(bool paused) external onlyOwner {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    /**
     * @notice Force sync reserves (emergency function)
     */
    function sync() external {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        _update(balance0, balance1, reserves.reserve0, reserves.reserve1);
    }
    
    /**
     * @notice Skim excess tokens (emergency function)
     */
    function skim(address to) external {
        IERC20 _token0 = token0;
        IERC20 _token1 = token1;
        _token0.safeTransfer(to, _token0.balanceOf(address(this)) - reserves.reserve0);
        _token1.safeTransfer(to, _token1.balanceOf(address(this)) - reserves.reserve1);
    }
}

// ============ Interfaces ============

interface IUniswapV2Factory {
    function feeTo() external view returns (address);
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}
