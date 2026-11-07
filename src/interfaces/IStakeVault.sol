// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Operator stake (Should tier)
interface IStakeVault {
    event Deposited(address indexed operator, uint256 amount);
    event Withdrawn(address indexed operator, uint256 amount);
    event Encumbered(address indexed operator, bytes32 indexed taskId, uint256 amount);
    event StakeReleased(address indexed operator, bytes32 indexed taskId, uint256 amount);
    event Slashed(address indexed operator, bytes32 indexed taskId, uint256 amount);

    error InsufficientFreeStake(address operator, uint256 free, uint256 needed);
    error TooManyOpenTasks(address operator, uint256 open, uint256 max);
    error NotEncumbered(bytes32 taskId);
    error StakeHeld(bytes32 taskId);
    error ReserveAlreadySet();

    /// @notice Deposits USDC into the caller's stake balance
    /// @param amount The amount of USDC to deposit
    function deposit(uint256 amount) external;

    /// @notice Free stake only
    /// @param amount The amount of USDC to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Returns the caller's free (unencumbered) stake
    /// @param operator The operator address to query
    /// @return The free stake amount
    function freeOf(address operator) external view returns (uint256);

    /// @notice Returns the total encumbered stake for an operator
    /// @param operator The operator address to query
    /// @return The encumbered stake amount
    function encumberedOf(address operator) external view returns (uint256);

    /// @notice Returns the number of open tasks for an operator
    /// @param operator The operator address to query
    /// @return The count of open tasks
    function openTasksOf(address operator) external view returns (uint256);

    /// @notice The stake a task holds; operator is zero once released or slashed.
    /// @param taskId The task to query
    /// @return operator The operator whose stake is held
    /// @return amount The amount of stake held
    /// @return held Whether the stake is currently held (frozen by an open challenge)
    function taskStake(bytes32 taskId) external view returns (address operator, uint256 amount, bool held);

    /// @notice ESCROW_ROLE
    /// @param operator The operator whose stake to encumber
    /// @param taskId The task to encumber stake for
    /// @param amount The amount to encumber
    function encumber(address operator, bytes32 taskId, uint256 amount) external;

    /// @notice ESCROW_ROLE
    /// @param taskId The task whose encumbered stake to release
    function release(bytes32 taskId) external;

    /// @notice HOLD_ROLE. While held (an open challenge), the task's stake cannot be released, only slashed.
    /// @param taskId The task whose stake to hold
    function hold(bytes32 taskId) external;

    /// @notice HOLD_ROLE
    /// @param taskId The task whose stake to unhold
    function unhold(bytes32 taskId) external;

    /// @notice Where slashed stake that is owed to nobody goes: the residual-loss reserve (paper §10.4).
    /// @return The reserve address
    function reserve() external view returns (address);

    /// @notice SLASHER_ROLE. Pays `amounts` to `to` in order, out of the task's encumbered stake.
    /// @param taskId The task whose stake to slash
    /// @param to The addresses to pay
    /// @param amounts The amounts to pay each address
    /// @return slashed The total amount slashed
    function slash(bytes32 taskId, address[] calldata to, uint256[] calldata amounts) external returns (uint256 slashed);
}
