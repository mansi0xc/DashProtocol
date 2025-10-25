// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenVesting
 * @notice Handles linear vesting of DASH tokens with cliff periods
 * @dev Supports multiple beneficiaries with individual vesting schedules
 *      Team allocation: 1 year cliff, 4 year linear vest
 *      Advisors: 6 month cliff, 2 year linear vest
 *      Foundation: 2 year cliff, 5 year linear vest
 */
contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    // ============ Structs ============
    
    struct VestingSchedule {
        uint256 totalAmount;        // Total tokens to vest
        uint256 cliff;              // Cliff period in seconds
        uint256 start;              // Start timestamp
        uint256 duration;           // Vesting duration in seconds
        uint256 released;           // Amount already released
        bool revocable;             // Can this schedule be revoked by owner
        bool revoked;               // Has this schedule been revoked
    }
    
    // ============ State Variables ============
    
    IERC20 public immutable token;
    
    mapping(address => VestingSchedule[]) private _vestingSchedules;
    mapping(address => uint256) public totalVestingCount;
    
    uint256 public totalVestedTokens;
    uint256 public totalReleasedTokens;
    
    // ============ Events ============
    
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 indexed scheduleId,
        uint256 totalAmount,
        uint256 cliff,
        uint256 start,
        uint256 duration,
        bool revocable
    );
    
    event TokensReleased(
        address indexed beneficiary,
        uint256 indexed scheduleId,
        uint256 amount,
        uint256 timestamp
    );
    
    event VestingScheduleRevoked(
        address indexed beneficiary,
        uint256 indexed scheduleId,
        uint256 returnedAmount,
        uint256 timestamp
    );
    
    // ============ Errors ============
    
    error InvalidDuration();
    error InvalidAmount();
    error InvalidBeneficiary();
    error ScheduleNotRevocable();
    error ScheduleAlreadyRevoked();
    error ScheduleNotFound();
    error NoTokensToRelease();
    error InsufficientContractBalance();
    
    // ============ Constructor ============
    
    constructor(IERC20 _token, address initialOwner) Ownable(initialOwner) {
        token = _token;
    }
    
    // ============ Main Functions ============
    
    /**
     * @notice Create a vesting schedule for a beneficiary
     * @param beneficiary The address of the beneficiary
     * @param totalAmount Total tokens to vest
     * @param cliff Cliff period in seconds
     * @param duration Total vesting duration in seconds
     * @param revocable Whether the schedule can be revoked
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 cliff,
        uint256 duration,
        bool revocable
    ) external onlyOwner returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (totalAmount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (token.balanceOf(address(this)) < totalVestedTokens + totalAmount) {
            revert InsufficientContractBalance();
        }
        
        uint256 start = block.timestamp;
        scheduleId = totalVestingCount[beneficiary];
        
        _vestingSchedules[beneficiary].push(VestingSchedule({
            totalAmount: totalAmount,
            cliff: cliff,
            start: start,
            duration: duration,
            released: 0,
            revocable: revocable,
            revoked: false
        }));
        
        totalVestingCount[beneficiary]++;
        totalVestedTokens += totalAmount;
        
        emit VestingScheduleCreated(
            beneficiary,
            scheduleId,
            totalAmount,
            cliff,
            start,
            duration,
            revocable
        );
    }
    
    /**
     * @notice Release vested tokens for a specific schedule
     * @param beneficiary The beneficiary address
     * @param scheduleId The schedule ID to release from
     */
    function release(address beneficiary, uint256 scheduleId) 
        external 
        nonReentrant 
        returns (uint256 releasedAmount) 
    {
        if (scheduleId >= totalVestingCount[beneficiary]) revert ScheduleNotFound();
        
        VestingSchedule storage schedule = _vestingSchedules[beneficiary][scheduleId];
        
        if (schedule.revoked) revert ScheduleAlreadyRevoked();
        
        releasedAmount = _releasableAmount(schedule);
        if (releasedAmount == 0) revert NoTokensToRelease();
        
        schedule.released += releasedAmount;
        totalReleasedTokens += releasedAmount;
        
        token.safeTransfer(beneficiary, releasedAmount);
        
        emit TokensReleased(beneficiary, scheduleId, releasedAmount, block.timestamp);
    }
    
    /**
     * @notice Release all available tokens for all schedules of a beneficiary
     * @param beneficiary The beneficiary address
     */
    function releaseAll(address beneficiary) external nonReentrant returns (uint256 totalReleased) {
        uint256 scheduleCount = totalVestingCount[beneficiary];
        
        for (uint256 i = 0; i < scheduleCount; i++) {
            VestingSchedule storage schedule = _vestingSchedules[beneficiary][i];
            
            if (!schedule.revoked) {
                uint256 releasable = _releasableAmount(schedule);
                if (releasable > 0) {
                    schedule.released += releasable;
                    totalReleasedTokens += releasable;
                    totalReleased += releasable;
                    
                    emit TokensReleased(beneficiary, i, releasable, block.timestamp);
                }
            }
        }
        
        if (totalReleased > 0) {
            token.safeTransfer(beneficiary, totalReleased);
        }
    }
    
    /**
     * @notice Revoke a vesting schedule (only if revocable)
     * @param beneficiary The beneficiary address
     * @param scheduleId The schedule ID to revoke
     */
    function revoke(address beneficiary, uint256 scheduleId) external onlyOwner {
        if (scheduleId >= totalVestingCount[beneficiary]) revert ScheduleNotFound();
        
        VestingSchedule storage schedule = _vestingSchedules[beneficiary][scheduleId];
        
        if (!schedule.revocable) revert ScheduleNotRevocable();
        if (schedule.revoked) revert ScheduleAlreadyRevoked();
        
        // Release any currently vested tokens first
        uint256 releasable = _releasableAmount(schedule);
        if (releasable > 0) {
            schedule.released += releasable;
            totalReleasedTokens += releasable;
            token.safeTransfer(beneficiary, releasable);
            
            emit TokensReleased(beneficiary, scheduleId, releasable, block.timestamp);
        }
        
        // Calculate and return unvested tokens to owner
        uint256 returnAmount = schedule.totalAmount - schedule.released;
        schedule.revoked = true;
        totalVestedTokens -= returnAmount;
        
        if (returnAmount > 0) {
            token.safeTransfer(owner(), returnAmount);
        }
        
        emit VestingScheduleRevoked(beneficiary, scheduleId, returnAmount, block.timestamp);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get vesting schedule details
     */
    function getVestingSchedule(address beneficiary, uint256 scheduleId)
        external
        view
        returns (VestingSchedule memory)
    {
        if (scheduleId >= totalVestingCount[beneficiary]) revert ScheduleNotFound();
        return _vestingSchedules[beneficiary][scheduleId];
    }
    
    /**
     * @notice Get all vesting schedules for a beneficiary
     */
    function getAllVestingSchedules(address beneficiary)
        external
        view
        returns (VestingSchedule[] memory)
    {
        return _vestingSchedules[beneficiary];
    }
    
    /**
     * @notice Calculate releasable amount for a schedule
     */
    function releasableAmount(address beneficiary, uint256 scheduleId)
        external
        view
        returns (uint256)
    {
        if (scheduleId >= totalVestingCount[beneficiary]) return 0;
        return _releasableAmount(_vestingSchedules[beneficiary][scheduleId]);
    }
    
    /**
     * @notice Get total releasable amount for all schedules of a beneficiary
     */
    function totalReleasableAmount(address beneficiary) external view returns (uint256 total) {
        uint256 scheduleCount = totalVestingCount[beneficiary];
        
        for (uint256 i = 0; i < scheduleCount; i++) {
            total += _releasableAmount(_vestingSchedules[beneficiary][i]);
        }
    }
    
    /**
     * @notice Calculate total vested amount for a schedule at current time
     */
    function vestedAmount(address beneficiary, uint256 scheduleId)
        external
        view
        returns (uint256)
    {
        if (scheduleId >= totalVestingCount[beneficiary]) return 0;
        return _vestedAmount(_vestingSchedules[beneficiary][scheduleId]);
    }
    
    /**
     * @notice Get comprehensive vesting summary for a beneficiary
     */
    function getVestingSummary(address beneficiary)
        external
        view
        returns (
            uint256 totalSchedules,
            uint256 totalAllocated,
            uint256 totalVested,
            uint256 totalReleased,
            uint256 totalReleasable
        )
    {
        totalSchedules = totalVestingCount[beneficiary];
        
        for (uint256 i = 0; i < totalSchedules; i++) {
            VestingSchedule memory schedule = _vestingSchedules[beneficiary][i];
            
            if (!schedule.revoked) {
                totalAllocated += schedule.totalAmount;
                totalVested += _vestedAmount(schedule);
                totalReleased += schedule.released;
                totalReleasable += _releasableAmount(schedule);
            }
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Calculate vested amount for a schedule
     */
    function _vestedAmount(VestingSchedule memory schedule) private view returns (uint256) {
        if (schedule.revoked) return 0;
        
        uint256 currentTime = block.timestamp;
        
        // Before cliff
        if (currentTime < schedule.start + schedule.cliff) {
            return 0;
        }
        
        // After full vesting period
        if (currentTime >= schedule.start + schedule.duration) {
            return schedule.totalAmount;
        }
        
        // During vesting period (linear)
        uint256 timeFromStart = currentTime - schedule.start;
        return (schedule.totalAmount * timeFromStart) / schedule.duration;
    }
    
    /**
     * @dev Calculate releasable amount for a schedule
     */
    function _releasableAmount(VestingSchedule memory schedule) private view returns (uint256) {
        return _vestedAmount(schedule) - schedule.released;
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency withdrawal of tokens (only unused tokens)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        uint256 availableBalance = token.balanceOf(address(this)) - (totalVestedTokens - totalReleasedTokens);
        require(amount <= availableBalance, "Insufficient available balance");
        
        token.safeTransfer(owner(), amount);
    }
    
    /**
     * @notice Get contract statistics
     */
    function getContractStats()
        external
        view
        returns (
            uint256 contractBalance,
            uint256 _totalVestedTokens,
            uint256 _totalReleasedTokens,
            uint256 availableForWithdrawal
        )
    {
        contractBalance = token.balanceOf(address(this));
        _totalVestedTokens = totalVestedTokens;
        _totalReleasedTokens = totalReleasedTokens;
        availableForWithdrawal = contractBalance - (totalVestedTokens - totalReleasedTokens);
    }
}
