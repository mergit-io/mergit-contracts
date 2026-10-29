// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IIdentity} from "./interfaces/IIdentity.sol";

/// @title Agent identity
/// @notice An agent is an ERC-721 token; its owner is the operator, who is paid for its work and posts its
///         stake. The runtime key signs the agent's receipts. ERC-8004-compatible in shape, not a full
///         ERC-8004 registry.
contract Identity is ERC721, IIdentity {
    uint256 private _next = 1;
    mapping(uint256 agentId => address) private _runtimeKey;
    mapping(uint256 agentId => string) private _uri;

    constructor() ERC721("Mergit Agent", "MAGENT") {}

    function registerAgent(address runtimeKey, string calldata metadataURI) external returns (uint256 agentId) {
        if (runtimeKey == address(0)) revert ZeroRuntimeKey();
        agentId = _next++;
        _runtimeKey[agentId] = runtimeKey;
        _uri[agentId] = metadataURI;
        _mint(msg.sender, agentId);
        emit AgentRegistered(agentId, msg.sender, runtimeKey, metadataURI);
    }

    function setRuntimeKey(uint256 agentId, address runtimeKey) external {
        if (operatorOf(agentId) != msg.sender) revert NotOperator(agentId, msg.sender);
        if (runtimeKey == address(0)) revert ZeroRuntimeKey();
        _runtimeKey[agentId] = runtimeKey;
        emit RuntimeKeyChanged(agentId, runtimeKey);
    }

    function runtimeKeyOf(uint256 agentId) external view returns (address) {
        _known(agentId);
        return _runtimeKey[agentId];
    }

    function operatorOf(uint256 agentId) public view returns (address) {
        _known(agentId);
        return ownerOf(agentId);
    }

    function tokenURI(uint256 agentId) public view override returns (string memory) {
        _known(agentId);
        return _uri[agentId];
    }

    /// @dev A transfer (not a mint) clears the runtime key: the seller's key must not sign for the buyer's
    ///      tasks, and with no key every commit fails until the new operator calls setRuntimeKey.
    function _update(address to, uint256 agentId, address auth) internal override returns (address from) {
        from = super._update(to, agentId, auth);
        if (from != address(0) && _runtimeKey[agentId] != address(0)) {
            delete _runtimeKey[agentId];
            emit RuntimeKeyChanged(agentId, address(0));
        }
    }

    function _known(uint256 agentId) private view {
        if (_ownerOf(agentId) == address(0)) revert UnknownAgent(agentId);
    }
}
