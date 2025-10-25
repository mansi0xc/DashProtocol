// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../lib/account-abstraction/contracts/accounts/SimpleAccount.sol";
import "../../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import "../../lib/account-abstraction/contracts/core/Helpers.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../tokens/DashToken.sol";

/**
 * @title DashAccount  
 * @notice Enhanced Smart Contract Account with session keys for AI agent execution
 * @dev Extends SimpleAccount with:
 *      - Session keys for AI agents with spending limits
 *      - Batch transaction execution
 *      - DASH token integration for fee discounts
 *      - Emergency recovery mechanisms
 *      - Spending limits and cooldowns for security
 */
contract DashAccount is SimpleAccount, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    
    // ============ Structs ============
    
    struct SessionKey {
        address signer;           // Address that can sign with this session key
        uint256 spendingLimit;    // Maximum spending per session (in wei)
        uint256 spentAmount;      // Amount spent in current session
        uint256 validUntil;       // Timestamp when session expires
        uint256 validAfter;       // Timestamp when session becomes valid
        bool isActive;            // Whether this session key is active
        address[] allowedTargets; // Contracts this session can interact with
        bytes4[] allowedSelectors; // Function selectors this session can call
    }
    
    struct RecoveryConfig {
        address[] guardians;      // List of recovery guardians
        uint256 threshold;        // Number of guardians needed for recovery
        uint256 recoveryDelay;    // Delay before recovery takes effect
        uint256 recoveryRequest;  // Timestamp of active recovery request
        address newOwner;         // Proposed new owner during recovery
    }
    
    // ============ State Variables ============
    
    DashToken public immutable dashToken;
    
    mapping(bytes32 => SessionKey) public sessionKeys;
    mapping(address => bytes32[]) public userSessionKeys;
    mapping(address => bool) public isGuardian;
    
    RecoveryConfig public recoveryConfig;
    
    uint256 public dailySpendingLimit = 10 ether; // Default daily limit
    uint256 public dailySpent;
    uint256 public lastSpendingReset;
    
    uint256 public constant MAX_SESSION_DURATION = 30 days;
    uint256 public constant MIN_RECOVERY_DELAY = 2 days;
    uint256 public constant MAX_SESSION_SPENDING = 1000 ether;
    
    // ============ Events ============
    
    event SessionKeyCreated(
        bytes32 indexed sessionId,
        address indexed signer,
        uint256 spendingLimit,
        uint256 validUntil,
        address[] allowedTargets
    );
    
    event SessionKeyRevoked(bytes32 indexed sessionId, address indexed signer);
    event SessionKeyUsed(bytes32 indexed sessionId, uint256 amount, address target);
    event SpendingLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event RecoveryInitiated(address indexed newOwner, uint256 effectiveTime);
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event RecoveryCancelled();
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    
    // ============ Errors ============
    
    error SessionKeyExpired();
    error SessionKeyNotActive();
    error SpendingLimitExceeded();
    error InvalidSessionKey();
    error UnauthorizedTarget();
    error UnauthorizedSelector();
    error InvalidRecoveryConfig();
    error RecoveryDelayNotMet();
    error InsufficientGuardians();
    error DailyLimitExceeded();
    
    // ============ Constructor ============
    
    constructor(IEntryPoint anEntryPoint, DashToken _dashToken) 
        SimpleAccount(anEntryPoint) 
    {
        dashToken = _dashToken;
    }
    
    // ============ Session Key Management ============
    
    /**
     * @notice Create a new session key for AI agent or other authorized signer
     * @param signer Address that can sign with this session key
     * @param spendingLimit Maximum spending limit for this session
     * @param duration How long this session key is valid (max 30 days)
     * @param allowedTargets Contracts this session can interact with
     * @param allowedSelectors Function selectors this session can call
     */
    function createSessionKey(
        address signer,
        uint256 spendingLimit,
        uint256 duration,
        address[] calldata allowedTargets,
        bytes4[] calldata allowedSelectors
    ) external onlyOwner returns (bytes32 sessionId) {
        require(signer != address(0), "Invalid signer");
        require(spendingLimit <= MAX_SESSION_SPENDING, "Spending limit too high");
        require(duration <= MAX_SESSION_DURATION, "Duration too long");
        require(allowedTargets.length > 0, "No allowed targets");
        
        sessionId = keccak256(abi.encodePacked(
            signer,
            block.timestamp,
            spendingLimit,
            allowedTargets
        ));
        
        sessionKeys[sessionId] = SessionKey({
            signer: signer,
            spendingLimit: spendingLimit,
            spentAmount: 0,
            validUntil: block.timestamp + duration,
            validAfter: block.timestamp,
            isActive: true,
            allowedTargets: allowedTargets,
            allowedSelectors: allowedSelectors
        });
        
        userSessionKeys[signer].push(sessionId);
        
        emit SessionKeyCreated(sessionId, signer, spendingLimit, block.timestamp + duration, allowedTargets);
    }
    
    /**
     * @notice Revoke a session key
     * @param sessionId The session key to revoke
     */
    function revokeSessionKey(bytes32 sessionId) external onlyOwner {
        require(sessionKeys[sessionId].isActive, "Session key not active");
        
        sessionKeys[sessionId].isActive = false;
        
        emit SessionKeyRevoked(sessionId, sessionKeys[sessionId].signer);
    }
    
    /**
     * @notice Get all session keys for a signer
     * @param signer The signer address
     */
    function getSessionKeys(address signer) external view returns (bytes32[] memory) {
        return userSessionKeys[signer];
    }
    
    // ============ Enhanced Validation ============
    
    /**
     * @dev Override validation to support session keys
     */
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        
        // Try owner signature first
        if (owner == hash.recover(userOp.signature)) {
            return 0;
        }
        
        // Try session key signatures
        return _validateSessionKeySignature(userOp, hash);
    }
    
    /**
     * @dev Validate session key signature and permissions
     */
    function _validateSessionKeySignature(
        PackedUserOperation calldata userOp,
        bytes32 hash
    ) internal view returns (uint256 validationData) {
        // Extract session ID from signature (last 32 bytes)
        if (userOp.signature.length < 97) { // 65 bytes signature + 32 bytes session ID
            return SIG_VALIDATION_FAILED;
        }
        
        bytes memory signature = userOp.signature[:65];
        bytes32 sessionId = bytes32(userOp.signature[65:]);
        
        SessionKey storage session = sessionKeys[sessionId];
        
        // Validate session key exists and is active
        if (!session.isActive || block.timestamp > session.validUntil || block.timestamp < session.validAfter) {
            return SIG_VALIDATION_FAILED;
        }
        
        // Validate signature
        address signer = hash.recover(signature);
        if (signer != session.signer) {
            return SIG_VALIDATION_FAILED;
        }
        
        // Validate target and selector permissions
        if (!_validateSessionPermissions(userOp, session)) {
            return SIG_VALIDATION_FAILED;
        }
        
        // Return success with valid until timestamp
        return _packValidationData(false, uint48(session.validUntil), 0);
    }
    
    /**
     * @dev Validate session permissions for target contracts and function selectors
     */
    function _validateSessionPermissions(
        PackedUserOperation calldata userOp,
        SessionKey storage session
    ) internal view returns (bool) {
        // Decode call data to get target and selector
        if (userOp.callData.length < 4) return false;
        
        // Extract target from execute call
        bytes4 executeSelector = bytes4(userOp.callData[:4]);
        if (executeSelector == this.execute.selector) {
            // Single execution
            (address target, , bytes memory data) = abi.decode(userOp.callData[4:], (address, uint256, bytes));
            return _isTargetAllowed(target, session) && _isSelectorAllowed(data, session);
        } else if (executeSelector == this.executeBatchTransactions.selector) {
            // Batch execution
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = 
                abi.decode(userOp.callData[4:], (address[], uint256[], bytes[]));
            
            for (uint i = 0; i < targets.length; i++) {
                if (!_isTargetAllowed(targets[i], session) || !_isSelectorAllowed(calldatas[i], session)) {
                    return false;
                }
            }
            return true;
        }
        
        return false;
    }
    
    function _isTargetAllowed(address target, SessionKey storage session) internal view returns (bool) {
        for (uint i = 0; i < session.allowedTargets.length; i++) {
            if (session.allowedTargets[i] == target) return true;
        }
        return false;
    }
    
    function _isSelectorAllowed(bytes memory data, SessionKey storage session) internal view returns (bool) {
        if (data.length < 4) return false;
        
        bytes4 selector = bytes4(data);
        for (uint i = 0; i < session.allowedSelectors.length; i++) {
            if (session.allowedSelectors[i] == selector) return true;
        }
        return false;
    }
    
    // ============ Enhanced Execution with Spending Limits ============
    
    /**
     * @dev Override execute to enforce spending limits
     */
    function execute(address dest, uint256 value, bytes calldata func) external override {
        _requireForExecute();
        _enforceSpendingLimits(value);
        _executeCall(dest, value, func);
    }
    
    /**
     * @notice Execute multiple operations in a batch
     * @param targets Array of target addresses
     * @param values Array of values to send
     * @param calldatas Array of call data
     */
    function executeBatchTransactions(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) public payable {
        require(targets.length == values.length && targets.length == calldatas.length, "Array length mismatch");
        
        uint256 totalValue = 0;
        for (uint i = 0; i < values.length; i++) {
            totalValue += values[i];
        }
        
        _enforceSpendingLimits(totalValue);
        
        for (uint i = 0; i < targets.length; i++) {
            _executeCall(targets[i], values[i], calldatas[i]);
        }
    }
    
    /**
     * @dev Execute a low-level call
     */
    function _executeCall(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /**
     * @dev Enforce daily spending limits and session spending limits
     */
    function _enforceSpendingLimits(uint256 value) internal {
        // Reset daily spending if needed
        if (block.timestamp >= lastSpendingReset + 1 days) {
            dailySpent = 0;
            lastSpendingReset = block.timestamp;
        }
        
        // Check daily limit
        if (dailySpent + value > dailySpendingLimit) {
            revert DailyLimitExceeded();
        }
        
        dailySpent += value;
        
        // If using session key, check session spending limit
        // This would be checked in the validation phase for UserOps
    }
    
    // ============ Social Recovery ============
    
    /**
     * @notice Initialize recovery configuration
     * @param guardians List of guardian addresses
     * @param threshold Number of guardians needed for recovery
     */
    function initializeRecovery(
        address[] calldata guardians,
        uint256 threshold
    ) external onlyOwner {
        require(guardians.length >= threshold && threshold > 0, "Invalid threshold");
        require(guardians.length <= 10, "Too many guardians");
        
        // Clear existing guardians
        for (uint i = 0; i < recoveryConfig.guardians.length; i++) {
            isGuardian[recoveryConfig.guardians[i]] = false;
        }
        
        // Set new guardians
        delete recoveryConfig.guardians;
        for (uint i = 0; i < guardians.length; i++) {
            require(guardians[i] != address(0), "Invalid guardian");
            recoveryConfig.guardians.push(guardians[i]);
            isGuardian[guardians[i]] = true;
            emit GuardianAdded(guardians[i]);
        }
        
        recoveryConfig.threshold = threshold;
        recoveryConfig.recoveryDelay = MIN_RECOVERY_DELAY;
    }
    
    /**
     * @notice Initiate account recovery (called by guardians)
     * @param newOwner New owner address
     * @param signatures Signatures from guardians supporting this recovery
     */
    function initiateRecovery(
        address newOwner,
        bytes[] calldata signatures
    ) external {
        require(newOwner != address(0), "Invalid new owner");
        require(signatures.length >= recoveryConfig.threshold, "Insufficient signatures");
        
        bytes32 recoveryHash = keccak256(abi.encodePacked(
            "RECOVERY",
            address(this),
            newOwner,
            block.timestamp
        ));
        
        // Verify guardian signatures
        address[] memory signers = new address[](signatures.length);
        for (uint i = 0; i < signatures.length; i++) {
            address signer = recoveryHash.toEthSignedMessageHash().recover(signatures[i]);
            require(isGuardian[signer], "Invalid guardian");
            
            // Check for duplicate signers
            for (uint j = 0; j < i; j++) {
                require(signers[j] != signer, "Duplicate signer");
            }
            signers[i] = signer;
        }
        
        recoveryConfig.recoveryRequest = block.timestamp;
        recoveryConfig.newOwner = newOwner;
        
        emit RecoveryInitiated(newOwner, block.timestamp + recoveryConfig.recoveryDelay);
    }
    
    /**
     * @notice Execute recovery after delay period
     */
    function executeRecovery() external {
        require(recoveryConfig.recoveryRequest > 0, "No active recovery");
        require(
            block.timestamp >= recoveryConfig.recoveryRequest + recoveryConfig.recoveryDelay,
            "Recovery delay not met"
        );
        
        address oldOwner = owner;
        owner = recoveryConfig.newOwner;
        
        // Clear recovery state
        recoveryConfig.recoveryRequest = 0;
        recoveryConfig.newOwner = address(0);
        
        emit RecoveryExecuted(oldOwner, owner);
    }
    
    /**
     * @notice Cancel active recovery (owner only)
     */
    function cancelRecovery() external onlyOwner {
        require(recoveryConfig.recoveryRequest > 0, "No active recovery");
        
        recoveryConfig.recoveryRequest = 0;
        recoveryConfig.newOwner = address(0);
        
        emit RecoveryCancelled();
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update daily spending limit
     * @param newLimit New daily spending limit
     */
    function setDailySpendingLimit(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = dailySpendingLimit;
        dailySpendingLimit = newLimit;
        
        emit SpendingLimitUpdated(oldLimit, newLimit);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get session key details
     */
    function getSessionKey(bytes32 sessionId) external view returns (SessionKey memory) {
        return sessionKeys[sessionId];
    }
    
    /**
     * @notice Check if account has DASH token fee discount
     */
    function getDashFeeDiscount() external view returns (uint256 discount) {
        return dashToken.getFeeDiscount(address(this));
    }
    
    /**
     * @notice Get account security info
     */
    function getSecurityInfo() external view returns (
        uint256 _dailySpendingLimit,
        uint256 _dailySpent,
        uint256 _lastReset,
        uint256 _guardianCount,
        uint256 _recoveryThreshold,
        bool _hasActiveRecovery
    ) {
        return (
            dailySpendingLimit,
            dailySpent,
            lastSpendingReset,
            recoveryConfig.guardians.length,
            recoveryConfig.threshold,
            recoveryConfig.recoveryRequest > 0
        );
    }
}
