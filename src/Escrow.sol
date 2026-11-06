// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {IIdentity} from "./interfaces/IIdentity.sol";
import {IReceiptRegistry} from "./interfaces/IReceiptRegistry.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";

/// @dev USDC's EIP-3009 receive path. Requires msg.sender == to, so a relayer cannot redirect the funds.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title Escrow for plans and tasks
/// @notice Money is locked before execution and moves only on an audit verdict, or, for the staked tier,
///         when the window passes with no verdict. Windows run on chain time (paper §10.1).
contract Escrow is AccessControl, ReentrancyGuard, IEscrow {
    using SafeERC20 for IERC20;

    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant CHALLENGE_ROLE = keccak256("CHALLENGE_ROLE");

    uint8 internal constant REASON_FAIL = 0;
    uint8 internal constant REASON_INVALID = 1;
    uint8 internal constant REASON_DEADLINE = 2;
    uint8 internal constant REASON_CHALLENGE = 3;

    /// @notice Stake encumbered per task, as basis points of V (a parameter, not a measurement). 1.5 x V covers
    ///         making the requester whole (V) plus the challenger reward (0.2 x V) on an already-paid task.
    uint256 public constant STAKE_RATIO_BPS = 15_000;

    struct Plan {
        address requester;
        Tier tier;
        uint256 available;
        bool closed;
        address refundTo;
    }

    struct Task {
        bytes32 planId;
        uint256 agentId;
        address payee;
        uint256 amount;
        uint64 deadline;
        TaskState state;
        Verdict verdict;
        uint64 settledAt;
    }

    IERC20 public immutable usdc;
    IIdentity public immutable identity;
    uint64 public immutable window;
    IReceiptRegistry public registry;
    IStakeVault public stakeVault;

    mapping(bytes32 planId => Plan) internal _plans;
    mapping(bytes32 taskId => Task) internal _tasks;
    mapping(bytes32 taskId => bytes32) public phiHashOf;
    mapping(bytes32 taskId => bool) public notDrawn;

    constructor(IERC20 usdc_, IIdentity identity_, uint64 window_) {
        usdc = usdc_;
        identity = identity_;
        window = window_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setRegistry(address registry_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(registry) != address(0)) revert RegistryAlreadySet();
        registry = IReceiptRegistry(registry_);
    }

    function setStakeVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(stakeVault) != address(0)) revert StakeVaultAlreadySet();
        stakeVault = IStakeVault(vault);
    }

    // ---- funding

    function fundPlan(bytes32 planId, uint256 amount) external nonReentrant {
        _credit(planId, msg.sender, amount, Tier.Staked, msg.sender);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    function fundPlanFor(bytes32 planId, address requester, uint256 amount)
        external
        nonReentrant
        onlyRole(TREASURY_ROLE)
    {
        _credit(planId, requester, amount, Tier.Onboarding, msg.sender);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

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
    ) external nonReentrant {
        bytes32 expected = keccak256(abi.encode(planId, amount));
        if (nonce != expected) revert NonceNotBoundToPlan(nonce, expected);
        _credit(planId, requester, amount, Tier.Staked, requester);
        IERC3009(address(usdc))
            .receiveWithAuthorization(requester, address(this), amount, validAfter, validBefore, nonce, v, r, s);
    }

    function _credit(bytes32 planId, address requester, uint256 amount, Tier tier, address refundTo) internal {
        if (amount == 0) revert ZeroAmount();
        Plan storage p = _plans[planId];
        if (p.requester == address(0)) {
            p.requester = requester;
            p.tier = tier;
            p.refundTo = refundTo;
        } else {
            if (p.closed) revert PlanClosedAlready(planId);
            if (p.requester != requester) revert NotPlanRequester(planId, requester);
            if (p.tier != tier) revert TierMismatch(planId);
        }
        p.available += amount;
        emit PlanFunded(planId, requester, msg.sender, amount, tier);
    }

    // ---- tasks

    function lockTask(bytes32 taskId, bytes32 planId, uint256 agentId, uint256 amount, uint64 deadline, bytes32 phiHash)
        external
        onlyRole(GATEWAY_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        if (deadline <= uint64(block.timestamp)) revert DeadlineInPast(taskId, deadline);
        if (_tasks[taskId].state != TaskState.None) revert TaskExists(taskId);
        Plan storage p = _plans[planId];
        if (p.closed) revert PlanClosedAlready(planId);
        if (p.available < amount) revert InsufficientPlanBalance(planId, p.available, amount);
        p.available -= amount;
        address payee = identity.operatorOf(agentId);
        _tasks[taskId] = Task(planId, agentId, payee, amount, deadline, TaskState.Locked, Verdict.None, 0);
        phiHashOf[taskId] = phiHash;
        emit TaskLocked(taskId, planId, agentId, payee, amount, deadline, phiHash);
        if (address(stakeVault) != address(0)) {
            stakeVault.encumber(payee, taskId, (amount * STAKE_RATIO_BPS) / 10_000);
        }
    }

    function recordVerdict(bytes32 taskId, Verdict verdict) external nonReentrant onlyRole(VALIDATOR_ROLE) {
        if (verdict == Verdict.None) revert InvalidVerdict();
        Task storage t = _locked(taskId);
        if (_committedAt(taskId) == 0) revert NoCommitment(taskId);
        t.verdict = verdict;
        emit VerdictRecorded(taskId, verdict);
        if (verdict == Verdict.Pass) {
            _release(taskId, t); // stake stays encumbered until finalize, after the window
        } else if (verdict == Verdict.Fail) {
            _return(taskId, t, REASON_FAIL);
            _releaseStake(taskId); // an honest miss: no slash
        } else {
            _return(taskId, t, REASON_INVALID);
            _slashToReserve(taskId); // a false receipt
        }
    }

    function releaseExpired(bytes32 taskId) external nonReentrant {
        Task storage t = _locked(taskId);
        uint64 committedAt = _committedAt(taskId);
        if (committedAt == 0) revert NoCommitment(taskId);
        if (_plans[t.planId].tier == Tier.Onboarding) revert OnboardingNeedsVerdict(taskId);
        uint256 endsAt = uint256(committedAt) + window;
        if (block.timestamp < endsAt) revert WindowNotOver(taskId, endsAt);
        // A drawn audit that never ran (validator down) must not turn into payment: only a task the validator
        // marked not drawn releases on expiry.
        if (!notDrawn[taskId]) revert AuditPending(taskId);
        _release(taskId, t);
        _releaseStake(taskId); // the window has already run
    }

    function returnExpired(bytes32 taskId) external nonReentrant {
        Task storage t = _locked(taskId);
        if (_committedAt(taskId) != 0) revert AlreadyCommitted(taskId);
        if (block.timestamp <= t.deadline) revert DeadlineNotPassed(taskId, t.deadline);
        _return(taskId, t, REASON_DEADLINE);
        _releaseStake(taskId); // non-emission is a failure, not a proven falsification
    }

    function markNotDrawn(bytes32 taskId) external onlyRole(VALIDATOR_ROLE) {
        Task storage t = _locked(taskId);
        if (_committedAt(taskId) == 0) revert NoCommitment(taskId);
        if (t.verdict != Verdict.None) revert VerdictAlreadyRecorded(taskId);
        notDrawn[taskId] = true;
    }

    function finalize(bytes32 taskId) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.state != TaskState.Released || t.verdict != Verdict.Pass) revert NotReleasedByVerdict(taskId);
        uint256 endsAt = uint256(t.settledAt) + window;
        if (block.timestamp < endsAt) revert WindowNotOver(taskId, endsAt);
        stakeVault.release(taskId);
    }

    function returnForChallenge(bytes32 taskId) external nonReentrant onlyRole(CHALLENGE_ROLE) {
        _return(taskId, _locked(taskId), REASON_CHALLENGE);
    }

    function refundAddressOf(bytes32 planId) external view returns (address) {
        return _refundAddress(_plans[planId]);
    }

    // ---- plans

    function closePlan(bytes32 planId) external nonReentrant {
        Plan storage p = _plans[planId];
        if (p.requester == address(0)) revert PlanUnknown(planId);
        if (msg.sender != p.requester && !hasRole(GATEWAY_ROLE, msg.sender)) {
            revert NotPlanRequester(planId, msg.sender);
        }
        if (p.closed) revert PlanClosedAlready(planId);
        uint256 refund = p.available;
        p.available = 0;
        p.closed = true;
        address to = _refundAddress(p);
        emit PlanClosed(planId, refund, to);
        if (refund > 0) usdc.safeTransfer(to, refund);
    }

    // ---- views

    function planOf(bytes32 planId)
        external
        view
        returns (address requester, Tier tier, uint256 available, bool closed)
    {
        Plan storage p = _plans[planId];
        return (p.requester, p.tier, p.available, p.closed);
    }

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
        )
    {
        Task storage t = _tasks[taskId];
        return (t.planId, t.agentId, t.payee, t.amount, t.deadline, t.state, t.verdict, t.settledAt);
    }

    // ---- internals

    function _locked(bytes32 taskId) internal view returns (Task storage t) {
        t = _tasks[taskId];
        if (t.state != TaskState.Locked) revert TaskNotLocked(taskId);
    }

    function _committedAt(bytes32 taskId) internal view returns (uint64) {
        return registry.commitmentOf(taskId).committedAt;
    }

    function _release(bytes32 taskId, Task storage t) internal {
        t.state = TaskState.Released;
        t.settledAt = uint64(block.timestamp);
        emit TaskReleased(taskId, t.payee, t.amount);
        usdc.safeTransfer(t.payee, t.amount);
    }

    /// @dev Back to the plan balance, or straight to the refund address if the plan has closed meanwhile,
    ///      so returned money is never stranded.
    function _return(bytes32 taskId, Task storage t, uint8 reason) internal {
        t.state = TaskState.Returned;
        t.settledAt = uint64(block.timestamp);
        Plan storage p = _plans[t.planId];
        emit TaskReturned(taskId, t.amount, reason);
        if (p.closed) {
            usdc.safeTransfer(_refundAddress(p), t.amount);
        } else {
            p.available += t.amount;
        }
    }

    function _releaseStake(bytes32 taskId) internal {
        if (address(stakeVault) != address(0)) stakeVault.release(taskId);
    }

    function _slashToReserve(bytes32 taskId) internal {
        if (address(stakeVault) == address(0)) return;
        address[] memory to = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        stakeVault.slash(taskId, to, amounts); // nothing named: the whole stake goes to the reserve
    }

    function _refundAddress(Plan storage p) internal view returns (address) {
        return p.tier == Tier.Onboarding ? p.refundTo : p.requester;
    }
}
