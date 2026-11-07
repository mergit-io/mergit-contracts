// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Validated outcomes (Should tier)
/// @notice Only audited verdicts and challenge rulings are recorded, never unaudited completions.
///         tier: 0 staked, 1 onboarding. source: 0 audit, 1 ruling.
interface IReputationAnchor {
    event OutcomeRecorded(
        bytes32 indexed taskId,
        uint256 indexed agentId,
        bytes32 category,
        bool success,
        uint256 costMicros,
        uint8 tier,
        uint8 source
    );

    error DuplicateRecord(bytes32 taskId, uint8 source);

    /// @notice RECORDER_ROLE
    /// @param taskId The task whose outcome to record
    /// @param agentId The agent that executed the task
    /// @param category An application-defined category tag
    /// @param success Whether the task completed successfully
    /// @param costMicros The execution cost in micro-units
    /// @param tier 0 for staked, 1 for onboarding
    /// @param source 0 for audit verdict, 1 for challenge ruling
    function record(
        bytes32 taskId,
        uint256 agentId,
        bytes32 category,
        bool success,
        uint256 costMicros,
        uint8 tier,
        uint8 source
    ) external;
}
