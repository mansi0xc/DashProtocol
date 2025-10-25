// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./GenericLiquidityPool.sol";
import "../tokens/DashToken.sol";

/**
 * @title PoolFactory
 * @notice Factory contract for creating and managing liquidity pools
 * @dev UniswapV2Factory-compatible with enhanced features:
 *      - Deterministic pool addresses using CREATE2
 *      - Global fee management
 *      - Pool registry and statistics
 *      - Integration with DASH token benefits
 *      - Multi-chain deployment support
 */
contract PoolFactory is Ownable, Pausable {
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    
    address public feeTo;
    address public feeToSetter;
    
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    
    // Enhanced features
    mapping(address => bool) public isPoolAuthorized;
    mapping(address => uint256) public poolCreationFee;
    mapping(address => PoolInfo) public poolInfo;
    
    struct PoolInfo {
        address token0;
        address token1;
        uint256 totalLiquidity;
        uint256 totalVolume;
        uint256 feesCollected;
        uint256 createdAt;
        bool isActive;
    }
    
    // Global settings
    uint256 public defaultProtocolFee = 1600; // 16% of LP fees
    uint256 public defaultFlashLoanFee = 3;   // 0.03%
    uint256 public defaultMaxSwapImpact = 1000; // 10%
    uint256 public poolCreationBaseFee = 0.1 ether; // ETH fee to create pool
    
    // Statistics
    uint256 public totalPools;
    uint256 public totalTVL; // Total Value Locked across all pools
    uint256 public totalVolume24h;
    uint256 public totalFeesGenerated;
    
    // Access control
    mapping(address => bool) public authorizedCreators;
    bool public publicPoolCreation = true;
    
    // ============ Events ============
    
    event PairCreated(
        address indexed token0, 
        address indexed token1, 
        address pair, 
        uint256 totalPairs
    );
    
    event PoolStatsUpdated(
        address indexed pool,
        uint256 newTVL,
        uint256 newVolume,
        uint256 newFees
    );
    
    event GlobalSettingsUpdated(
        uint256 protocolFee,
        uint256 flashLoanFee,
        uint256 maxSwapImpact
    );
    
    event PoolCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event AuthorizedCreatorUpdated(address indexed creator, bool authorized);
    
    // ============ Errors ============
    
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();
    error InsufficientFee();
    error PoolCreationDisabled();
    error InvalidFeeRange();
    
    // ============ Constructor ============
    
    constructor(
        address _dashToken,
        address _feeToSetter,
        address initialOwner
    ) Ownable(initialOwner) {
        dashToken = DashToken(_dashToken);
        feeToSetter = _feeToSetter;
        feeTo = initialOwner;
        
        // Authorize owner as creator
        authorizedCreators[initialOwner] = true;
    }
    
    // ============ Core Functions ============
    
    /**
     * @notice Create a new liquidity pool for token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair Address of created pool
     */
    function createPair(address tokenA, address tokenB) 
        external 
        payable 
        whenNotPaused 
        returns (address pair) 
    {
        // Access control
        if (!publicPoolCreation && !authorizedCreators[msg.sender]) {
            revert PoolCreationDisabled();
        }
        
        // Validate inputs
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();
        
        // Check creation fee
        uint256 requiredFee = _getPoolCreationFee(msg.sender);
        if (msg.value < requiredFee) revert InsufficientFee();
        
        // Create pool using CREATE2 for deterministic addresses
        bytes memory bytecode = type(GenericLiquidityPool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        pair = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                bytecode,
                abi.encode(token0, token1, address(dashToken), feeTo, address(this))
            )
        );
        
        // Initialize pool in registry
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        
        // Set pool info
        poolInfo[pair] = PoolInfo({
            token0: token0,
            token1: token1,
            totalLiquidity: 0,
            totalVolume: 0,
            feesCollected: 0,
            createdAt: block.timestamp,
            isActive: true
        });
        
        isPoolAuthorized[pair] = true;
        totalPools++;
        
        // Send creation fee to fee collector (if any)
        if (msg.value > 0) {
            payable(feeTo).transfer(msg.value);
        }
        
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    
    /**
     * @notice Batch create multiple pools
     * @param tokenPairs Array of token pair arrays [[tokenA1, tokenB1], [tokenA2, tokenB2], ...]
     * @return pairs Array of created pool addresses
     */
    function batchCreatePairs(address[][] calldata tokenPairs) 
        external
        payable
        whenNotPaused
        returns (address[] memory pairs) 
    {
        uint256 pairCount = tokenPairs.length;
        pairs = new address[](pairCount);
        
        uint256 totalFeeRequired = _getPoolCreationFee(msg.sender) * pairCount;
        if (msg.value < totalFeeRequired) revert InsufficientFee();
        
        for (uint256 i = 0; i < pairCount; i++) {
            require(tokenPairs[i].length == 2, "INVALID_PAIR");
            // Internal call doesn't require additional fee
            pairs[i] = _createPairInternal(tokenPairs[i][0], tokenPairs[i][1]);
        }
        
        // Send total fee to fee collector
        if (msg.value > 0) {
            payable(feeTo).transfer(msg.value);
        }
    }
    
    /**
     * @notice Get deterministic pool address before deployment
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair Predicted pool address
     */
    function predictPairAddress(address tokenA, address tokenB) 
        external 
        view 
        returns (address pair) 
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        bytes memory bytecode = type(GenericLiquidityPool).creationCode;
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(
                    bytecode,
                    abi.encode(token0, token1, address(dashToken), feeTo, address(this))
                ))
            )
        );
        
        pair = address(uint160(uint256(hash)));
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get total number of pools
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
    
    /**
     * @notice Get pool creation fee for specific user
     */
    function getPoolCreationFee(address creator) external view returns (uint256) {
        return _getPoolCreationFee(creator);
    }
    
    /**
     * @notice Get comprehensive pool statistics
     */
    function getPoolStats(address pool) external view returns (
        address token0,
        address token1,
        uint256 totalSupply,
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalVolume,
        uint256 feesCollected,
        bool isActive
    ) {
        PoolInfo memory info = poolInfo[pool];
        token0 = info.token0;
        token1 = info.token1;
        totalVolume = info.totalVolume;
        feesCollected = info.feesCollected;
        isActive = info.isActive;
        
        if (pool != address(0)) {
            GenericLiquidityPool poolContract = GenericLiquidityPool(pool);
            totalSupply = poolContract.totalSupply();
            (uint112 _reserve0, uint112 _reserve1,) = poolContract.getReserves();
            reserve0 = uint256(_reserve0);
            reserve1 = uint256(_reserve1);
        }
    }
    
    /**
     * @notice Get global DEX statistics
     */
    function getGlobalStats() external view returns (
        uint256 _totalPools,
        uint256 _totalTVL,
        uint256 _totalVolume24h,
        uint256 _totalFeesGenerated,
        uint256 _dashHolderBenefits
    ) {
        _totalPools = totalPools;
        _totalTVL = totalTVL;
        _totalVolume24h = totalVolume24h;
        _totalFeesGenerated = totalFeesGenerated;
        
        // Calculate estimated benefits for DASH holders
        _dashHolderBenefits = (_totalFeesGenerated * defaultProtocolFee) / 10000;
    }
    
    /**
     * @notice Get all pools for a specific token
     */
    function getPoolsForToken(address token) external view returns (address[] memory pools) {
        uint256 count = 0;
        
        // Count matching pools
        for (uint256 i = 0; i < allPairs.length; i++) {
            PoolInfo memory info = poolInfo[allPairs[i]];
            if (info.token0 == token || info.token1 == token) {
                count++;
            }
        }
        
        // Populate array
        pools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allPairs.length; i++) {
            PoolInfo memory info = poolInfo[allPairs[i]];
            if (info.token0 == token || info.token1 == token) {
                pools[index] = allPairs[i];
                index++;
            }
        }
    }
    
    /**
     * @notice Check if pool exists and is active
     */
    function isValidPool(address pool) external view returns (bool) {
        return isPoolAuthorized[pool] && poolInfo[pool].isActive;
    }
    
    // ============ Internal Functions ============
    
    function _createPairInternal(address tokenA, address tokenB) internal returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();
        
        bytes memory bytecode = type(GenericLiquidityPool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        pair = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                bytecode,
                abi.encode(token0, token1, address(dashToken), feeTo, address(this))
            )
        );
        
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        
        poolInfo[pair] = PoolInfo({
            token0: token0,
            token1: token1,
            totalLiquidity: 0,
            totalVolume: 0,
            feesCollected: 0,
            createdAt: block.timestamp,
            isActive: true
        });
        
        isPoolAuthorized[pair] = true;
        totalPools++;
        
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    
    function _getPoolCreationFee(address creator) internal view returns (uint256) {
        // DASH holders get discounts
        uint256 dashBalance = dashToken.balanceOf(creator);
        uint256 discount = dashToken.getFeeDiscount(creator);
        
        uint256 baseFee = poolCreationBaseFee;
        
        // Apply DASH discount
        if (discount > 0) {
            baseFee = (baseFee * (10000 - discount)) / 10000;
        }
        
        // Authorized creators get additional discount
        if (authorizedCreators[creator]) {
            baseFee = baseFee / 2; // 50% discount
        }
        
        return baseFee;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Set fee recipient
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeTo = _feeTo;
    }
    
    /**
     * @notice Set fee setter
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
    
    /**
     * @notice Update global protocol settings
     */
    function updateGlobalSettings(
        uint256 _protocolFee,
        uint256 _flashLoanFee,
        uint256 _maxSwapImpact
    ) external onlyOwner {
        if (_protocolFee > 2500) revert InvalidFeeRange(); // Max 25%
        if (_flashLoanFee > 100) revert InvalidFeeRange();  // Max 1%
        if (_maxSwapImpact < 100 || _maxSwapImpact > 5000) revert InvalidFeeRange(); // 1% to 50%
        
        defaultProtocolFee = _protocolFee;
        defaultFlashLoanFee = _flashLoanFee;
        defaultMaxSwapImpact = _maxSwapImpact;
        
        emit GlobalSettingsUpdated(_protocolFee, _flashLoanFee, _maxSwapImpact);
    }
    
    /**
     * @notice Set pool creation fee
     */
    function setPoolCreationFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = poolCreationBaseFee;
        poolCreationBaseFee = newFee;
        emit PoolCreationFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @notice Set authorized creator status
     */
    function setAuthorizedCreator(address creator, bool authorized) external onlyOwner {
        authorizedCreators[creator] = authorized;
        emit AuthorizedCreatorUpdated(creator, authorized);
    }
    
    /**
     * @notice Toggle public pool creation
     */
    function setPublicPoolCreation(bool enabled) external onlyOwner {
        publicPoolCreation = enabled;
    }
    
    /**
     * @notice Update pool statistics (called by pools)
     */
    function updatePoolStats(
        address pool,
        uint256 newTVL,
        uint256 volumeIncrease,
        uint256 feesIncrease
    ) external {
        require(isPoolAuthorized[msg.sender], "UNAUTHORIZED");
        
        PoolInfo storage info = poolInfo[pool];
        info.totalLiquidity = newTVL;
        info.totalVolume += volumeIncrease;
        info.feesCollected += feesIncrease;
        
        // Update global stats
        totalTVL = totalTVL - info.totalLiquidity + newTVL;
        totalVolume24h += volumeIncrease;
        totalFeesGenerated += feesIncrease;
        
        emit PoolStatsUpdated(pool, newTVL, info.totalVolume, info.feesCollected);
    }
    
    /**
     * @notice Deactivate a pool (emergency function)
     */
    function deactivatePool(address pool) external onlyOwner {
        require(isPoolAuthorized[pool], "POOL_NOT_EXISTS");
        poolInfo[pool].isActive = false;
        isPoolAuthorized[pool] = false;
    }
    
    /**
     * @notice Pause/unpause factory
     */
    function setPaused(bool paused) external onlyOwner {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    /**
     * @notice Emergency withdrawal of stuck ETH
     */
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    // ============ Receive ETH ============
    
    receive() external payable {
        // Allow receiving ETH for pool creation fees
    }
}
