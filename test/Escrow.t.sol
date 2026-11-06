// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract EscrowTest is Test {
    uint64 constant WINDOW = 600;
    bytes32 constant PLAN = keccak256("plan");
    bytes32 constant PHI = keccak256("approved predicate");

    MockUSDC usdc;
    Identity id;
    ReceiptRegistry reg;
    Escrow escrow;

    uint256 runtimePk = 0xA11CE;
    uint256 requesterPk = 0xB0B;
    address requester;
    address operator = makeAddr("operator");
    address gateway = makeAddr("gateway");
    address validator = makeAddr("validator");
    address treasury = makeAddr("treasury");
    uint256 agentId;

    function setUp() public {
        requester = vm.addr(requesterPk);
        usdc = new MockUSDC();
        id = new Identity();
        reg = new ReceiptRegistry(id);
        escrow = new Escrow(usdc, id, WINDOW);
        reg.setEscrow(address(escrow));
        escrow.setRegistry(address(reg));
        escrow.grantRole(escrow.GATEWAY_ROLE(), gateway);
        escrow.grantRole(escrow.VALIDATOR_ROLE(), validator);
        escrow.grantRole(escrow.TREASURY_ROLE(), treasury);
        vm.prank(operator);
        agentId = id.registerAgent(vm.addr(runtimePk), "");
        usdc.mint(requester, 100e6);
        usdc.mint(treasury, 100e6);
        vm.prank(requester);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(treasury);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ---- helpers

    function fund(uint256 amount) internal {
        vm.prank(requester);
        escrow.fundPlan(PLAN, amount);
    }

    function lock(bytes32 taskId, uint256 amount) internal {
        vm.prank(gateway);
        escrow.lockTask(taskId, PLAN, agentId, amount, uint64(block.timestamp + 1800), PHI);
    }

    function commit(bytes32 taskId) internal {
        bytes32 structHash = keccak256(
            abi.encode(reg.RECEIPT_TYPEHASH(), taskId, bytes32("root"), bytes32("term"), bytes32("body"), uint256(1))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mergit"),
                keccak256("0"),
                block.chainid,
                address(reg)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(runtimePk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 1, abi.encodePacked(r, s, v));
    }

    function verdict(bytes32 taskId, IEscrow.Verdict v) internal {
        vm.prank(validator);
        escrow.recordVerdict(taskId, v);
    }

    function available() internal view returns (uint256 a) {
        (,, a,) = escrow.planOf(PLAN);
    }

    function state(bytes32 taskId) internal view returns (IEscrow.TaskState s) {
        (,,,,, s,,) = escrow.taskOf(taskId);
    }

    // ---- funding

    function test_fundPlanPullsUsdcAndRecordsRequester() public {
        vm.expectEmit(true, true, false, true);
        emit IEscrow.PlanFunded(PLAN, requester, requester, 5e6, IEscrow.Tier.Staked);
        fund(5e6);
        (address who, IEscrow.Tier tier, uint256 avail, bool closed) = escrow.planOf(PLAN);
        assertEq(who, requester);
        assertEq(uint8(tier), uint8(IEscrow.Tier.Staked));
        assertEq(avail, 5e6);
        assertFalse(closed);
        assertEq(usdc.balanceOf(address(escrow)), 5e6);
    }

    function test_fundingTwiceAddsToTheSamePlan() public {
        fund(2e6);
        fund(3e6);
        assertEq(available(), 5e6);
    }

    function test_zeroAmountIsRejected() public {
        vm.prank(requester);
        vm.expectRevert(IEscrow.ZeroAmount.selector);
        escrow.fundPlan(PLAN, 0);
    }

    function test_otherAddressCannotFundSomeoneElsesPlan() public {
        fund(1e6);
        address other = makeAddr("other");
        usdc.mint(other, 1e6);
        vm.startPrank(other);
        usdc.approve(address(escrow), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.NotPlanRequester.selector, PLAN, other));
        escrow.fundPlan(PLAN, 1e6);
        vm.stopPrank();
    }

    function test_onlyTreasuryFundsOnboardingPlans() public {
        vm.prank(requester);
        vm.expectRevert();
        escrow.fundPlanFor(PLAN, requester, 1e6);

        vm.prank(treasury);
        escrow.fundPlanFor(PLAN, requester, 1e6);
        (, IEscrow.Tier tier,,) = escrow.planOf(PLAN);
        assertEq(uint8(tier), uint8(IEscrow.Tier.Onboarding));
    }

    function test_requesterCannotTopUpOnboardingPlanAsStaked() public {
        vm.prank(treasury);
        escrow.fundPlanFor(PLAN, requester, 1e6);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.TierMismatch.selector, PLAN));
        escrow.fundPlan(PLAN, 1e6);
    }

    // ---- gasless funding (EIP-3009)

    function authorization(uint256 amount, bytes32 nonce) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                requester,
                address(escrow),
                amount,
                uint256(0),
                block.timestamp + 1 hours,
                nonce
            )
        );
        return vm.sign(requesterPk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_fundWithAuthorizationPullsFromRequester() public {
        bytes32 nonce = keccak256(abi.encode(PLAN, uint256(4e6)));
        (uint8 v, bytes32 r, bytes32 s) = authorization(4e6, nonce);
        vm.prank(gateway); // anyone may relay; the gateway pays the gas
        escrow.fundPlanWithAuthorization(PLAN, requester, 4e6, 0, block.timestamp + 1 hours, nonce, v, r, s);
        assertEq(available(), 4e6);
        (address who,,,) = escrow.planOf(PLAN);
        assertEq(who, requester);
    }

    function test_fundWithAuthorizationRejectsNonceNotBoundToPlan() public {
        bytes32 nonce = keccak256("some other plan");
        (uint8 v, bytes32 r, bytes32 s) = authorization(4e6, nonce);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEscrow.NonceNotBoundToPlan.selector, nonce, keccak256(abi.encode(PLAN, uint256(4e6)))
            )
        );
        escrow.fundPlanWithAuthorization(PLAN, requester, 4e6, 0, block.timestamp + 1 hours, nonce, v, r, s);
    }

    // ---- locking

    function test_lockTaskOnlyGatewayAndWithinAvailable() public {
        fund(2e6);
        vm.expectRevert();
        escrow.lockTask("t1", PLAN, agentId, 1e6, uint64(block.timestamp + 60), PHI);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientPlanBalance.selector, PLAN, 2e6, 3e6));
        escrow.lockTask("t1", PLAN, agentId, 3e6, uint64(block.timestamp + 60), PHI);

        lock("t1", 2e6);
        (, uint256 a, address payee, uint256 amount,, IEscrow.TaskState s,,) = escrow.taskOf("t1");
        assertEq(a, agentId);
        assertEq(payee, operator);
        assertEq(amount, 2e6);
        assertEq(uint8(s), uint8(IEscrow.TaskState.Locked));
        assertEq(available(), 0);
    }

    function test_lockTaskRevertsWhenDeadlineEqualsTimestamp() public {
        fund(2e6);
        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(IEscrow.DeadlineInPast.selector, bytes32("t1"), uint64(block.timestamp))
        );
        escrow.lockTask("t1", PLAN, agentId, 1e6, uint64(block.timestamp), PHI);
    }

    function test_lockTaskSucceedsWhenDeadlineIsTimestampPlusOne() public {
        fund(2e6);
        vm.prank(gateway);
        escrow.lockTask("t1", PLAN, agentId, 1e6, uint64(block.timestamp + 1), PHI);
        assertEq(uint8(state("t1")), uint8(IEscrow.TaskState.Locked));
    }

    function test_lockTaskTwiceIsRejected() public {
        fund(2e6);
        lock("t1", 1e6);
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.TaskExists.selector, bytes32("t1")));
        escrow.lockTask("t1", PLAN, agentId, 1e6, uint64(block.timestamp + 60), PHI);
    }

    // ---- verdicts

    function test_passReleasesToOperatorAtOnce() public {
        fund(2e6);
        lock("t1", 2e6);
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        assertEq(usdc.balanceOf(operator), 2e6);
        assertEq(uint8(state("t1")), uint8(IEscrow.TaskState.Released));
        (,,,,,, IEscrow.Verdict v, uint64 settledAt) = escrow.taskOf("t1");
        assertEq(uint8(v), uint8(IEscrow.Verdict.Pass));
        assertEq(settledAt, uint64(block.timestamp));
    }

    function test_failReturnsToPlanBalance() public {
        fund(2e6);
        lock("t1", 2e6);
        commit("t1");
        vm.expectEmit(true, false, false, true);
        emit IEscrow.TaskReturned("t1", 2e6, 0);
        verdict("t1", IEscrow.Verdict.Fail);
        assertEq(available(), 2e6);
        assertEq(usdc.balanceOf(operator), 0);
    }

    function test_invalidReturnsToPlanBalanceWithReasonInvalid() public {
        fund(2e6);
        lock("t1", 2e6);
        commit("t1");
        vm.expectEmit(true, false, false, true);
        emit IEscrow.TaskReturned("t1", 2e6, 1);
        verdict("t1", IEscrow.Verdict.Invalid);
        assertEq(available(), 2e6);
    }

    function test_retryAfterFailLocksFromReturnedBalance() public {
        fund(2e6);
        lock("attempt1", 2e6);
        commit("attempt1");
        verdict("attempt1", IEscrow.Verdict.Fail);
        lock("attempt2", 2e6); // no new funding needed
        commit("attempt2");
        verdict("attempt2", IEscrow.Verdict.Pass);
        assertEq(usdc.balanceOf(operator), 2e6);
        assertEq(available(), 0);
    }

    function test_verdictNeedsCommitment() public {
        fund(1e6);
        lock("t1", 1e6);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.NoCommitment.selector, bytes32("t1")));
        escrow.recordVerdict("t1", IEscrow.Verdict.Pass);
    }

    function test_onlyValidatorRecordsVerdicts() public {
        fund(1e6);
        lock("t1", 1e6);
        commit("t1");
        vm.prank(operator);
        vm.expectRevert();
        escrow.recordVerdict("t1", IEscrow.Verdict.Pass);
    }

    function test_verdictNoneIsRejected() public {
        fund(1e6);
        lock("t1", 1e6);
        commit("t1");
        vm.prank(validator);
        vm.expectRevert(IEscrow.InvalidVerdict.selector);
        escrow.recordVerdict("t1", IEscrow.Verdict.None);
    }

    function test_noReleaseTwice() public {
        fund(1e6);
        lock("t1", 1e6);
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.TaskNotLocked.selector, bytes32("t1")));
        escrow.recordVerdict("t1", IEscrow.Verdict.Pass);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.TaskNotLocked.selector, bytes32("t1")));
        escrow.releaseExpired("t1");
        assertEq(usdc.balanceOf(operator), 1e6);
    }

    // ---- expiry

    function test_releaseExpiredOnlyAfterWindowWithoutVerdict() public {
        fund(1e6);
        lock("t1", 1e6);
        commit("t1");
        uint256 endsAt = block.timestamp + WINDOW;
        vm.expectRevert(abi.encodeWithSelector(IEscrow.WindowNotOver.selector, bytes32("t1"), endsAt));
        escrow.releaseExpired("t1");
        vm.warp(endsAt);
        vm.prank(validator);
        escrow.markNotDrawn("t1");
        escrow.releaseExpired("t1");
        assertEq(usdc.balanceOf(operator), 1e6);
    }

    function test_releaseExpiredNeedsCommitment() public {
        fund(1e6);
        lock("t1", 1e6);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.NoCommitment.selector, bytes32("t1")));
        escrow.releaseExpired("t1");
    }

    function test_onboardingTaskCannotReleaseWithoutVerdict() public {
        vm.prank(treasury);
        escrow.fundPlanFor(PLAN, requester, 1e6);
        lock("t1", 1e6);
        commit("t1");
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.OnboardingNeedsVerdict.selector, bytes32("t1")));
        escrow.releaseExpired("t1");
    }

    function test_returnExpiredOnlyWithoutCommitmentAfterDeadline() public {
        fund(1e6);
        lock("t1", 1e6);
        (,,,, uint64 deadline,,,) = escrow.taskOf("t1");
        vm.expectRevert(abi.encodeWithSelector(IEscrow.DeadlineNotPassed.selector, bytes32("t1"), deadline));
        escrow.returnExpired("t1");
        vm.warp(deadline + 1);
        escrow.returnExpired("t1");
        assertEq(available(), 1e6);
        assertEq(uint8(state("t1")), uint8(IEscrow.TaskState.Returned));
    }

    function test_returnExpiredRefusedOnceCommitted() public {
        fund(1e6);
        lock("t1", 1e6);
        commit("t1");
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.AlreadyCommitted.selector, bytes32("t1")));
        escrow.returnExpired("t1");
    }

    // ---- closing

    function test_closePlanRefundsRequesterOrTreasury() public {
        fund(3e6);
        lock("t1", 1e6);
        uint256 before = usdc.balanceOf(requester);
        vm.prank(requester);
        escrow.closePlan(PLAN);
        assertEq(usdc.balanceOf(requester), before + 2e6);
        (,,, bool closed) = escrow.planOf(PLAN);
        assertTrue(closed);

        bytes32 credits = keccak256("credits plan");
        vm.prank(treasury);
        escrow.fundPlanFor(credits, requester, 2e6);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(gateway);
        escrow.closePlan(credits);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 2e6, "credits go back to the treasury, not the requester");
    }

    function test_onlyRequesterOrGatewayClosesPlan() public {
        fund(1e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.NotPlanRequester.selector, PLAN, operator));
        escrow.closePlan(PLAN);
    }

    function test_closedPlanCannotBeFundedOrLocked() public {
        fund(2e6);
        vm.prank(requester);
        escrow.closePlan(PLAN);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.PlanClosedAlready.selector, PLAN));
        escrow.fundPlan(PLAN, 1e6);
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.PlanClosedAlready.selector, PLAN));
        escrow.lockTask("t1", PLAN, agentId, 1e6, uint64(block.timestamp + 60), PHI);
    }

    function test_returnAfterPlanClosedRefundsDirectly() public {
        fund(2e6);
        lock("t1", 2e6);
        vm.prank(requester);
        escrow.closePlan(PLAN);
        commit("t1");
        uint256 before = usdc.balanceOf(requester);
        verdict("t1", IEscrow.Verdict.Fail);
        assertEq(usdc.balanceOf(requester), before + 2e6, "money returned to a closed plan must not be stranded");
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ---- conservation

    function testFuzz_balanceConservation(uint96 funded, uint96 lockA, uint96 lockB, uint8 outcome) public {
        funded = uint96(bound(funded, 2, 50e6));
        lockA = uint96(bound(lockA, 1, funded / 2));
        lockB = uint96(bound(lockB, 1, funded - lockA));
        fund(funded);
        lock("a", lockA);
        lock("b", lockB);
        commit("a");
        commit("b");
        verdict("a", IEscrow.Verdict(1 + (outcome % 3)));
        uint256 locked = lockB + (state("a") == IEscrow.TaskState.Locked ? lockA : 0);
        assertEq(usdc.balanceOf(address(escrow)), available() + locked);
        if (outcome % 2 == 0) {
            vm.prank(requester);
            escrow.closePlan(PLAN);
            assertEq(usdc.balanceOf(address(escrow)), lockB);
        }
    }
}
