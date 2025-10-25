// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "../lib/account-abstraction/contracts/interfaces/ISenderCreator.sol";
import "../lib/account-abstraction/contracts/accounts/SimpleAccount.sol";
import "./DashAccount.sol";
import "./DashToken.sol";

/**
 * @title DashAccountFactory
 * @notice Factory for creating DashAccount instances with deterministic addresses
 * @dev Creates minimal proxy contracts for gas efficiency
 *      Supports CREATE2 for predictable addresses
 *      Integrates with ERC-4337 EntryPoint system
 */
contract DashAccountFactory is Ownable {
    
    // ============ State Variables ============
    
    DashAccount public immutable accountImplementation;
    IEntryPoint public immutable entryPoint;
    ISenderCreator public immutable senderCreator;
    DashToken public immutable dashToken;
    
    mapping(address => bool) public isValidAccount;
    mapping(address => address[]) public userAccounts;
    
    uint256 public totalAccountsCreated;
    uint256 public accountCreationFee = 0; // Free for now, can be updated
    
    // ============ Events ============
    
    event AccountCreated(
        address indexed account,
        address indexed owner,
        uint256 salt,
        uint256 timestamp
    );
    
    event AccountCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    
    // ============ Constructor ============
    
    constructor(
        IEntryPoint _entryPoint,
        DashToken _dashToken,
        address initialOwner
    ) Ownable(initialOwner) {
        entryPoint = _entryPoint;
        senderCreator = _entryPoint.senderCreator();
        dashToken = _dashToken;
        
        // Deploy implementation contract
        accountImplementation = new DashAccount(_entryPoint, _dashToken);
    }
    
    // ============ Account Creation ============
    
    /**
     * @notice Create a new DashAccount
     * @param owner The owner of the new account
     * @param salt Salt for CREATE2 (use 0 for default)
     * @return account The address of the created account
     */
    function createAccount(
        address owner,
        uint256 salt
    ) public payable returns (DashAccount account) {
        require(owner != address(0), "Invalid owner");
        require(msg.value >= accountCreationFee, "Insufficient fee");
        
        // Only SenderCreator can call during UserOp execution
        if (msg.sender != address(senderCreator)) {
            require(msg.sender == owner || msg.sender == address(this) || msg.sender == this.owner(), "Unauthorized");
        }
        
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        
        if (codeSize > 0) {
            return DashAccount(payable(addr));
        }
        
        account = DashAccount(payable(
            new ERC1967Proxy{salt: bytes32(salt)}(
                address(accountImplementation),
                abi.encodeCall(SimpleAccount.initialize, (owner))
            )
        ));
        
        // Track the account
        isValidAccount[address(account)] = true;
        userAccounts[owner].push(address(account));
        totalAccountsCreated++;
        
        emit AccountCreated(address(account), owner, salt, block.timestamp);
    }
    
    /**
     * @notice Create account with initial session key for AI agent
     * @param owner The owner of the new account  
     * @param salt Salt for CREATE2
     * @param aiSigner AI agent address for session key
     * @param spendingLimit Spending limit for AI agent
     * @param duration Duration of session key
     * @param allowedTargets Contracts AI can interact with
     * @param allowedSelectors Function selectors AI can call
     */
    function createAccountWithSessionKey(
        address owner,
        uint256 salt,
        address aiSigner,
        uint256 spendingLimit,
        uint256 duration,
        address[] calldata allowedTargets,
        bytes4[] calldata allowedSelectors
    ) external payable returns (DashAccount account) {
        account = createAccount(owner, salt);
        
        // Create session key for AI agent (owner needs to call this)
        // Note: This would require a separate transaction from the owner
        // or batch execution capability
    }
    
    /**
     * @notice Get the counterfactual address of an account
     * @param owner The owner of the account
     * @param salt Salt for CREATE2
     * @return The predicted address
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    address(accountImplementation),
                    abi.encodeCall(SimpleAccount.initialize, (owner))
                )
            ))
        );
    }
    
    /**
     * @notice Batch create multiple accounts (for testing/setup)
     * @param owners Array of account owners
     * @param salts Array of salts
     */
    function batchCreateAccounts(
        address[] calldata owners,
        uint256[] calldata salts
    ) external payable returns (DashAccount[] memory accounts) {
        require(owners.length == salts.length, "Array length mismatch");
        require(msg.value >= accountCreationFee * owners.length, "Insufficient fee");
        
        accounts = new DashAccount[](owners.length);
        
        for (uint256 i = 0; i < owners.length; i++) {
            accounts[i] = createAccount(owners[i], salts[i]);
        }
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update account creation fee
     * @param newFee New fee amount
     */
    function setAccountCreationFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = accountCreationFee;
        accountCreationFee = newFee;
        
        emit AccountCreationFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @notice Withdraw collected fees
     * @param to Address to send fees to
     */
    function withdrawFees(address payable to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        
        to.transfer(balance);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get all accounts created by a user
     * @param owner The user address
     * @return Array of account addresses
     */
    function getUserAccounts(address owner) external view returns (address[] memory) {
        return userAccounts[owner];
    }
    
    /**
     * @notice Get factory statistics
     */
    function getFactoryStats() external view returns (
        uint256 _totalAccountsCreated,
        uint256 _accountCreationFee,
        address _implementation,
        address _entryPoint,
        address _dashToken
    ) {
        return (
            totalAccountsCreated,
            accountCreationFee,
            address(accountImplementation),
            address(entryPoint),
            address(dashToken)
        );
    }
    
    /**
     * @notice Check if an address is a valid DashAccount created by this factory
     * @param account The address to check
     * @return True if it's a valid account
     */
    function isAccount(address account) external view returns (bool) {
        return isValidAccount[account];
    }
    
    /**
     * @notice Get implementation address
     */
    function implementation() external view returns (address) {
        return address(accountImplementation);
    }
    
    // ============ Helper Functions for Frontend Integration ============
    
    /**
     * @notice Generate deterministic salt for user
     * @param owner User address
     * @param nonce User's nonce (to create multiple accounts)
     * @return Generated salt
     */
    function generateSalt(address owner, uint256 nonce) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(owner, nonce, "DashAccount")));
    }
    
    /**
     * @notice Preview account address without creating
     * @param owner Future account owner
     * @param nonce User's nonce
     * @return Predicted account address
     */
    function previewAccountAddress(
        address owner,
        uint256 nonce
    ) external view returns (address) {
        uint256 salt = generateSalt(owner, nonce);
        return getAddress(owner, salt);
    }
    
    /**
     * @notice Get account creation cost including gas estimates
     * @return creationFee The fee in wei
     * @return estimatedGas Estimated gas for account creation
     */
    function getCreationCost() external view returns (uint256 creationFee, uint256 estimatedGas) {
        return (accountCreationFee, 250000); // Estimated gas for account creation
    }
}
