// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Receipt commitments
/// @notice Stores one commitment per task. The EIP-712 signature must recover to the agent's runtime key.
///         Typehash: Receipt(bytes32 taskId,bytes32 root,bytes32 terminalHash,bytes32 bodyHash,uint256 costMicros),
///         domain name "Mergit", version "0" (spec/receipt-v0.md).
interface IReceiptRegistry {
    struct Commitment {
        uint256 agentId;
        bytes32 root;
        bytes32 terminalHash;
        bytes32 bodyHash;
        uint256 costMicros;
        uint64 committedAt;
    }

    event ReceiptCommitted(
        bytes32 indexed taskId,
        uint256 indexed agentId,
        bytes32 root,
        bytes32 terminalHash,
        bytes32 bodyHash,
        uint256 costMicros
    );

    error EscrowAlreadySet();
    error AlreadyCommitted(bytes32 taskId);
    error TaskNotLocked(bytes32 taskId);
    error AgentMismatch(bytes32 taskId, uint256 expected, uint256 given);
    error BadSignature(address recovered, address expected);

    /// @notice Admin, once
    /// @param escrow The escrow contract address to bind to
    function setEscrow(address escrow) external;

    /// @notice Commits a receipt for a locked task. The signature must recover to the agent's runtime key.
    /// @param taskId The task this receipt covers
    /// @param agentId The agent that produced the receipt
    /// @param root The Merkle root of the receipt body
    /// @param terminalHash The hash of the terminal state
    /// @param bodyHash The hash of the full receipt body
    /// @param costMicros The execution cost in micro-units
    /// @param signature The EIP-712 signature over the receipt fields
    function commit(
        bytes32 taskId,
        uint256 agentId,
        bytes32 root,
        bytes32 terminalHash,
        bytes32 bodyHash,
        uint256 costMicros,
        bytes calldata signature
    ) external;

    /// @notice Returns the commitment for a task
    /// @param taskId The task to query
    /// @return The commitment struct; committedAt is 0 when the task has no commitment
    function commitmentOf(bytes32 taskId) external view returns (Commitment memory);
}
