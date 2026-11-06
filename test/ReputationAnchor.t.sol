// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakeBase} from "./StakeBase.t.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IReputationAnchor} from "../src/interfaces/IReputationAnchor.sol";

/// ReputationAnchor tests.
contract ReputationAnchorTest is StakeBase {
    function test_anchorRejectsNonRecorder() public {
        vm.prank(operator);
        vm.expectRevert();
        anchor.record("t1", agentId, "test-repair", true, 1, 0, 0);
    }

    function test_anchorRecordsTierAndRefusesDuplicates() public {
        vm.expectEmit(true, true, false, true);
        emit IReputationAnchor.OutcomeRecorded("t1", agentId, "test-repair", true, 41, 1, 0);
        vm.prank(validator);
        anchor.record("t1", agentId, "test-repair", true, 41, 1, 0);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IReputationAnchor.DuplicateRecord.selector, bytes32("t1"), uint8(0)));
        anchor.record("t1", agentId, "test-repair", true, 41, 1, 0);
    }

    function test_rulingIsAnchoredAsAFailure() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.expectEmit(true, true, false, false);
        emit IReputationAnchor.OutcomeRecorded("t1", agentId, bytes32(0), false, 0, 0, 1);
        vm.prank(adjudicator);
        cm.resolve(cid, true);
    }

    // ---- new: OutcomeRecorded event field assertions

    function test_outcomeRecordedEmitsAllFields() public {
        vm.expectEmit(true, true, false, true);
        emit IReputationAnchor.OutcomeRecorded(
            "task-abc", agentId, "code-review", false, 9999, 0, 0
        );
        vm.prank(validator);
        anchor.record("task-abc", agentId, "code-review", false, 9999, 0, 0);

        assertTrue(anchor.recorded("task-abc", 0));
    }

    function test_sameTaskRecordedUnderBothSources() public {
        vm.prank(validator);
        anchor.record("t2", agentId, "deploy", true, 100, 0, 0);
        assertTrue(anchor.recorded("t2", 0));
        assertFalse(anchor.recorded("t2", 1));

        vm.prank(address(cm));
        anchor.record("t2", agentId, bytes32(0), false, 0, 0, 1);
        assertTrue(anchor.recorded("t2", 0));
        assertTrue(anchor.recorded("t2", 1));
    }

    function test_duplicateUnderSameSourceReverts() public {
        vm.prank(validator);
        anchor.record("t3", agentId, "build", true, 50, 1, 0);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IReputationAnchor.DuplicateRecord.selector, bytes32("t3"), uint8(0)));
        anchor.record("t3", agentId, "build", true, 50, 1, 0);
    }
}
