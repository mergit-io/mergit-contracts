// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {IIdentity} from "../src/interfaces/IIdentity.sol";

contract IdentityTest is Test {
    Identity id;
    address operator = makeAddr("operator");
    address runtime = makeAddr("runtime");

    function setUp() public {
        id = new Identity();
    }

    function test_registerAgentMintsToOperator() public {
        vm.prank(operator);
        uint256 agentId = id.registerAgent(runtime, "ipfs://agent-1");
        assertEq(agentId, 1);
        assertEq(id.ownerOf(agentId), operator);
        assertEq(id.operatorOf(agentId), operator);
        assertEq(id.runtimeKeyOf(agentId), runtime);
        assertEq(id.tokenURI(agentId), "ipfs://agent-1");
    }

    function test_agentIdsIncrease() public {
        address op2 = makeAddr("operator2");
        vm.prank(operator);
        uint256 first = id.registerAgent(runtime, "ipfs://agent-1");

        address runtime2 = makeAddr("runtime2");
        vm.prank(op2);
        uint256 second = id.registerAgent(runtime2, "ipfs://agent-2");

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(id.ownerOf(first), operator);
        assertEq(id.ownerOf(second), op2);
    }

    function test_registerAgentEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IIdentity.AgentRegistered(1, operator, runtime, "ipfs://a");
        vm.prank(operator);
        id.registerAgent(runtime, "ipfs://a");
    }

    function test_registerRejectsZeroRuntimeKey() public {
        vm.expectRevert(IIdentity.ZeroRuntimeKey.selector);
        id.registerAgent(address(0), "");
    }

    function test_onlyOwnerSetsRuntimeKey() public {
        vm.prank(operator);
        uint256 agentId = id.registerAgent(runtime, "");
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIdentity.NotOperator.selector, agentId, stranger));
        id.setRuntimeKey(agentId, stranger);

        address next = makeAddr("next");
        vm.expectEmit(true, false, false, true);
        emit IIdentity.RuntimeKeyChanged(agentId, next);
        vm.prank(operator);
        id.setRuntimeKey(agentId, next);
        assertEq(id.runtimeKeyOf(agentId), next);
    }

    function test_setRuntimeKeyRejectsUnknownAgent() public {
        address next = makeAddr("next");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IIdentity.UnknownAgent.selector, 42));
        id.setRuntimeKey(42, next);
    }

    function test_setRuntimeKeyRejectsZeroAddress() public {
        vm.prank(operator);
        uint256 agentId = id.registerAgent(runtime, "");

        vm.prank(operator);
        vm.expectRevert(IIdentity.ZeroRuntimeKey.selector);
        id.setRuntimeKey(agentId, address(0));
    }

    function test_transferMovesOperatorAndClearsRuntimeKey() public {
        vm.prank(operator);
        uint256 agentId = id.registerAgent(runtime, "");
        address buyer = makeAddr("buyer");
        vm.prank(operator);
        id.transferFrom(operator, buyer, agentId);
        assertEq(id.operatorOf(agentId), buyer);
        // #16: the seller's key must not sign for the buyer; the buyer sets a new one (see IdentityTransfer.t.sol).
        assertEq(id.runtimeKeyOf(agentId), address(0));
    }

    function test_unknownAgentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IIdentity.UnknownAgent.selector, 42));
        id.runtimeKeyOf(42);
    }

    function test_tokenURIOfUnknownAgentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IIdentity.UnknownAgent.selector, 42));
        id.tokenURI(42);
    }
}
