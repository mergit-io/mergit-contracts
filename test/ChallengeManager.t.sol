// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakeBase} from "./StakeBase.t.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IStakeVault} from "../src/interfaces/IStakeVault.sol";
import {IChallengeManager} from "../src/interfaces/IChallengeManager.sol";

/// ChallengeManager tests.
contract ChallengeManagerTest is StakeBase {
    function test_challengeOnlyInsideWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.OutsideWindow.selector, bytes32("t1")));
        cm.open("t1");
    }

    function test_challengeNeedsACommitment() public {
        lock("t1");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.NoCommitment.selector, bytes32("t1")));
        cm.open("t1");
    }

    function test_bondIsTenPercentOfVWithAOneUsdcFloor() public {
        lock("t1");
        assertEq(cm.bondFor("t1"), 1e6, "10% of 2 USDC is below the 1 USDC floor");
    }

    function test_openChallengeHoldsStakePastTheWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.prank(challenger);
        cm.open("t1");
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.StakeHeld.selector, bytes32("t1")));
        escrow.finalize("t1");
    }

    function test_upheldChallengeOnReleasedTaskPaysRequesterThenChallengerThenReserve() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass); // operator already paid V
        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 challengerBefore = usdc.balanceOf(challenger);
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, true);
        assertEq(usdc.balanceOf(requester), requesterBefore + V, "1: requester made whole from stake");
        assertEq(usdc.balanceOf(challenger), challengerBefore + (V * 2000) / 10_000, "2: bond back plus 20% of V");
        assertEq(usdc.balanceOf(reserve), S - V - (V * 2000) / 10_000, "3: the rest of the stake to the reserve");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_upheldChallengeOnHeldTaskReturnsVThroughEscrow() public {
        lock("t1");
        commit("t1"); // no verdict: held until the window ends
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, true);
        (,,,,, IEscrow.TaskState s,,) = escrow.taskOf("t1");
        assertEq(uint8(s), uint8(IEscrow.TaskState.Returned));
        assertEq(available(), 20e6, "V returned to the plan");
        assertEq(
            usdc.balanceOf(reserve), S - (V * 2000) / 10_000, "stake after the challenger's reward goes to the reserve"
        );
    }

    function test_rejectedChallengeSplitsBondAndFreesStake() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        uint256 operatorBefore = usdc.balanceOf(operator);
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, false);
        assertEq(usdc.balanceOf(operator), operatorBefore + 0.5e6, "half the bond to the operator");
        assertEq(usdc.balanceOf(reserve), 0.5e6, "half to the adjudication reserve");
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize("t1");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_onlyAdjudicatorResolvesAndOnlyOnce() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(challenger);
        vm.expectRevert();
        cm.resolve(cid, true);
        vm.prank(adjudicator);
        cm.resolve(cid, false);
        vm.prank(adjudicator);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.AlreadyResolved.selector, cid));
        cm.resolve(cid, true);
    }

    function test_oneChallengePerTask() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        cm.open("t1");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.AlreadyChallenged.selector, bytes32("t1")));
        cm.open("t1");
    }
}
