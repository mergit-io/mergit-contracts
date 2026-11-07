// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Agent identity, ERC-8004-compatible in shape
/// @notice Each agent is an ERC-721 token owned by its operator. The runtime key signs the agent's receipts.
interface IIdentity {
    event AgentRegistered(uint256 indexed agentId, address indexed operator, address runtimeKey, string metadataURI);
    event RuntimeKeyChanged(uint256 indexed agentId, address runtimeKey);

    error ZeroRuntimeKey();
    error NotOperator(uint256 agentId, address caller);
    error UnknownAgent(uint256 agentId);

    /// @notice Registers a new agent, minted to msg.sender as its operator
    /// @param runtimeKey The address that will sign receipts on behalf of this agent
    /// @param metadataURI An off-chain URI describing the agent
    /// @return agentId The token id of the newly registered agent
    function registerAgent(address runtimeKey, string calldata metadataURI) external returns (uint256 agentId);

    /// @notice Operator only
    /// @param agentId The agent whose runtime key to change
    /// @param runtimeKey The new runtime key address
    function setRuntimeKey(uint256 agentId, address runtimeKey) external;

    /// @notice Returns the current runtime key for an agent
    /// @param agentId The agent to query
    /// @return The address of the agent's runtime key
    function runtimeKeyOf(uint256 agentId) external view returns (address);

    /// @notice The token owner
    /// @param agentId The agent to query
    /// @return The address of the agent's operator
    function operatorOf(uint256 agentId) external view returns (address);
}
