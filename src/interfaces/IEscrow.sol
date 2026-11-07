// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Escrow for plans and tasks
/// @notice A requester funds a plan once; each task's amount is locked from the plan before execution and
///         released on a passing verdict or, for the staked tier, after the window with no verdict.
interface IEscrow {
    enum Tier {
        Staked,
        Onboarding
    }

    enum TaskState {
        None,
        Locked,
        Released,
        Returned
    }

    enum Verdict {
        None,
        Pass,
        Fail,
        Invalid
    }

    /// @dev reason: 0 fail, 1 invalid, 2 deadline, 3 challenge
    event PlanFunded(bytes32 indexed planId, address indexed requester, address funder, uint256 amount, Tier tier);
    event TaskLocked(
        bytes32 indexed taskId,
        bytes32 indexed planId,
        uint256 agentId,
        address payee,
        uint256 amount,
        uint64 deadline,
        bytes32 phiHash
    );
    event VerdictRecorded(bytes32 indexed taskId, Verdict verdict);
    event TaskReleased(bytes32 indexed taskId, address payee, uint256 amount);
    event TaskReturned(bytes32 indexed taskId, uint256 amount, uint8 reason);
    event PlanClosed(bytes32 indexed planId, uint256 refund, address to);

    error RegistryAlreadySet();
    error ZeroAmount();
    error PlanClosedAlready(bytes32 planId);
    error NotPlanRequester(bytes32 planId, address caller);
    error TierMismatch(bytes32 planId);
    error InsufficientPlanBalance(bytes32 planId, uint256 available, uint256 needed);
    error TaskExists(bytes32 taskId);
    error TaskNotLocked(bytes32 taskId);
    error NoCommitment(bytes32 taskId);
    error AlreadyCommitted(bytes32 taskId);
    error VerdictAlreadyRecorded(bytes32 taskId);
    error InvalidVerdict();
    error WindowNotOver(bytes32 taskId, uint256 endsAt);
    error DeadlineNotPassed(bytes32 taskId, uint64 deadline);
    error OnboardingNeedsVerdict(bytes32 taskId);
    error NonceNotBoundToPlan(bytes32 nonce, bytes32 expected);
    error StakeVaultAlreadySet();
    error PlanUnknown(bytes32 planId);
    error AuditPending(bytes32 taskId);
    error NotReleasedByVerdict(bytes32 taskId);

    /// @notice Admin, once
    /// @param registry The receipt registry contract address
    function setRegistry(address registry) external;

    /// @notice requester = msg.sender; Tier.Staked
    /// @param planId The plan to fund
    /// @param amount The USDC amount to deposit
    function fundPlan(bytes32 planId, uint256 amount) external;

    /// @notice TREASURY_ROLE; Tier.Onboarding (free credits)
    /// @param planId The plan to fund
    /// @param requester The address credited as plan requester
    /// @param amount The USDC amount to deposit
    function fundPlanFor(bytes32 planId, address requester, uint256 amount) external;

    /// @notice Gasless funding with a USDC EIP-3009 receiveWithAuthorization signed by the requester.
    ///         nonce must equal keccak256(abi.encode(planId, amount)).
    /// @param planId The plan to fund
    /// @param requester The address that signed the authorization
    /// @param amount The USDC amount to deposit
    /// @param validAfter The earliest unix timestamp the authorization is valid
    /// @param validBefore The latest unix timestamp the authorization is valid
    /// @param nonce Must equal keccak256(abi.encode(planId, amount))
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    function fundPlanWithAuthorization(
        bytes32 planId,
        address requester,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice GATEWAY_ROLE. The payee is the agent's operator at lock time. `phiHash` is the approved predicate's
    ///         hash; a receipt for this task is valid only if its header carries the same hash.
    /// @param taskId Unique identifier for the task
    /// @param planId The plan to draw funds from
    /// @param agentId The agent assigned to the task
    /// @param amount The USDC amount to lock
    /// @param deadline Unix timestamp after which the task can be returned
    /// @param phiHash Hash of the approved predicate
    function lockTask(bytes32 taskId, bytes32 planId, uint256 agentId, uint256 amount, uint64 deadline, bytes32 phiHash)
        external;

    /// @notice Returns the predicate hash committed at lock time
    /// @param taskId The task to query
    /// @return The phi hash
    function phiHashOf(bytes32 taskId) external view returns (bytes32);

    /// @notice Returns whether the task was marked as not drawn by the validator
    /// @param taskId The task to query
    /// @return True if the validator marked the task as not drawn
    function notDrawn(bytes32 taskId) external view returns (bool);

    /// @notice VALIDATOR_ROLE. The audit was not drawn, so the task may release when its window ends.
    /// @param taskId The task to mark as not drawn
    function markNotDrawn(bytes32 taskId) external;

    /// @notice VALIDATOR_ROLE. Needs a commitment in ReceiptRegistry.
    /// @param taskId The task to record a verdict for
    /// @param verdict The verdict to record
    function recordVerdict(bytes32 taskId, Verdict verdict) external;

    /// @notice Anyone. Staked tier only: committed, no verdict, marked not drawn by the validator, window over.
    /// @param taskId The task whose locked funds to release to the payee
    function releaseExpired(bytes32 taskId) external;

    /// @notice Anyone. Locked, no commitment, and past the deadline.
    /// @param taskId The task whose locked funds to return to the plan
    function returnExpired(bytes32 taskId) external;

    /// @notice Anyone. After a passing verdict, once the window has run, releases the agent's stake.
    /// @param taskId The task to finalize
    function finalize(bytes32 taskId) external;

    /// @notice CHALLENGE_ROLE. An upheld challenge on a task not yet paid: V goes back to the plan (reason 3).
    /// @param taskId The task whose funds to return
    function returnForChallenge(bytes32 taskId) external;

    /// @notice Admin, once. Without a vault, tasks need no stake.
    /// @param vault The stake vault contract address
    function setStakeVault(address vault) external;

    /// @notice Who is made whole for a plan: the requester, or the treasury for a credits plan.
    /// @param planId The plan to query
    /// @return The address that receives refunds
    function refundAddressOf(bytes32 planId) external view returns (address);

    /// @notice The requester or GATEWAY_ROLE. Refunds the unspent balance to the requester, or to the
    ///         treasury for an onboarding plan.
    /// @param planId The plan to close
    function closePlan(bytes32 planId) external;

    /// @notice Returns the state of a plan
    /// @param planId The plan to query
    /// @return requester The plan's requester address
    /// @return tier The plan's tier
    /// @return available The remaining balance
    /// @return closed Whether the plan is closed
    function planOf(bytes32 planId) external view returns (address requester, Tier tier, uint256 available, bool closed);

    /// @notice Returns the full state of a task
    /// @param taskId The task to query
    /// @return planId The plan the task draws from
    /// @return agentId The assigned agent
    /// @return payee The address that receives payment on release
    /// @return amount The locked USDC amount
    /// @return deadline The return-eligible timestamp
    /// @return state The current task state
    /// @return verdict The recorded verdict
    /// @return settledAt The timestamp the task was settled
    function taskOf(bytes32 taskId)
        external
        view
        returns (
            bytes32 planId,
            uint256 agentId,
            address payee,
            uint256 amount,
            uint64 deadline,
            TaskState state,
            Verdict verdict,
            uint64 settledAt
        );

    /// @notice Returns the window duration in seconds
    /// @return The window duration
    function window() external view returns (uint64);
}
