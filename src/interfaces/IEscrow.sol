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
    error DeadlineInPast(bytes32 taskId, uint64 deadline);
    error StakeVaultAlreadySet();
    error PlanUnknown(bytes32 planId);
    error AuditPending(bytes32 taskId);
    error NotReleasedByVerdict(bytes32 taskId);

    /// @notice Admin, once
    function setRegistry(address registry) external;

    /// @notice requester = msg.sender; Tier.Staked
    function fundPlan(bytes32 planId, uint256 amount) external;

    /// @notice TREASURY_ROLE; Tier.Onboarding (free credits)
    function fundPlanFor(bytes32 planId, address requester, uint256 amount) external;

    /// @notice Gasless funding with a USDC EIP-3009 receiveWithAuthorization signed by the requester.
    ///         nonce must equal keccak256(abi.encode(planId, amount)).
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
    function lockTask(bytes32 taskId, bytes32 planId, uint256 agentId, uint256 amount, uint64 deadline, bytes32 phiHash)
        external;

    function phiHashOf(bytes32 taskId) external view returns (bytes32);

    function notDrawn(bytes32 taskId) external view returns (bool);

    /// @notice VALIDATOR_ROLE. The audit was not drawn, so the task may release when its window ends.
    function markNotDrawn(bytes32 taskId) external;

    /// @notice VALIDATOR_ROLE. Needs a commitment in ReceiptRegistry.
    function recordVerdict(bytes32 taskId, Verdict verdict) external;

    /// @notice Anyone. Staked tier only: committed, no verdict, marked not drawn by the validator, window over.
    function releaseExpired(bytes32 taskId) external;

    /// @notice Anyone. Locked, no commitment, and past the deadline.
    function returnExpired(bytes32 taskId) external;

    /// @notice Anyone. After a passing verdict, once the window has run, releases the agent's stake.
    function finalize(bytes32 taskId) external;

    /// @notice CHALLENGE_ROLE. An upheld challenge on a task not yet paid: V goes back to the plan (reason 3).
    function returnForChallenge(bytes32 taskId) external;

    /// @notice Admin, once. Without a vault, tasks need no stake.
    function setStakeVault(address vault) external;

    /// @notice Who is made whole for a plan: the requester, or the treasury for a credits plan.
    function refundAddressOf(bytes32 planId) external view returns (address);

    /// @notice The requester or GATEWAY_ROLE. Refunds the unspent balance to the requester, or to the
    ///         treasury for an onboarding plan.
    function closePlan(bytes32 planId) external;

    function planOf(bytes32 planId) external view returns (address requester, Tier tier, uint256 available, bool closed);

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

    function window() external view returns (uint64);
}
