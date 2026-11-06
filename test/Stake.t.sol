// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakeBase} from "./StakeBase.t.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IStakeVault} from "../src/interfaces/IStakeVault.sol";

/// StakeVault tests, wired as the Deploy script wires them.
contract StakeTest is StakeBase {
    // ---- StakeVault

    function test_lockEncumbersOneAndAHalfTimesV() public {
        lock("t1");
        assertEq(vault.encumberedOf(operator), S);
        assertEq(vault.freeOf(operator), 10e6 - S);
        assertEq(vault.openTasksOf(operator), 1);
    }

    function test_cannotWithdrawEncumberedStake() public {
        lock("t1");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.InsufficientFreeStake.selector, operator, 10e6 - S, 10e6));
        vault.withdraw(10e6);
        vm.prank(operator);
        vault.withdraw(10e6 - S);
    }

    function test_lockFailsWithoutEnoughFreeStake() public {
        lock("t1");
        lock("t2");
        lock("t3"); // 9 of 10 USDC encumbered
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.InsufficientFreeStake.selector, operator, 1e6, S));
        escrow.lockTask("t4", PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function test_capOnOpenTasksPerOperator() public {
        vm.prank(operator);
        vault.deposit(90e6);
        vm.prank(requester);
        escrow.fundPlan(PLAN, 80e6);
        for (uint256 i = 0; i < 5; i++) {
            lock(bytes32(i + 1));
        }
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.TooManyOpenTasks.selector, operator, 5, 5));
        escrow.lockTask("six", PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function test_failReleasesStakeAtOnce() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Fail);
        assertEq(vault.encumberedOf(operator), 0);
        assertEq(vault.openTasksOf(operator), 0);
    }

    function test_finalizeReleasesStakeOnlyAfterWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.expectRevert();
        escrow.finalize("t1");
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize("t1");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_invalidVerdictReturnsVAndSlashesStakeToReserve() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Invalid);
        assertEq(available(), 20e6, "V back in the plan: the requester is whole");
        assertEq(usdc.balanceOf(reserve), S, "the encumbered stake is slashed to the reserve");
        assertEq(vault.encumberedOf(operator), 0);
        assertEq(vault.freeOf(operator), 10e6 - S);
    }
}
