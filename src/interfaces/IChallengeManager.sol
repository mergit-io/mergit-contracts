// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Bonded challenge (Should tier). Adjudicated by the platform in v0, open decision D9.
interface IChallengeManager {
    event ChallengeOpened(uint256 indexed challengeId, bytes32 indexed taskId, address challenger, uint256 bond);
    event ChallengeResolved(uint256 indexed challengeId, bytes32 indexed taskId, bool upheld);

    error NoCommitment(bytes32 taskId);
    error OutsideWindow(bytes32 taskId);
    error AlreadyChallenged(bytes32 taskId); // one open challenge per task at a time
    error UnknownChallenge(uint256 challengeId);
    error AlreadyResolved(uint256 challengeId);

    /// @notice Pulls the bond: max(1e6, amount x 1000 / 10000) USDC units
    /// @param taskId The task to challenge
    /// @return challengeId The id assigned to the new challenge
    function open(bytes32 taskId) external returns (uint256 challengeId);

    /// @notice ADJUDICATOR_ROLE
    /// @param challengeId The challenge to resolve
    /// @param upheld True if the challenge is upheld; false to dismiss
    function resolve(uint256 challengeId, bool upheld) external;

    /// @notice Returns the bond required to challenge a task
    /// @param taskId The task to compute the bond for
    /// @return The bond amount in USDC units
    function bondFor(bytes32 taskId) external view returns (uint256);
}
