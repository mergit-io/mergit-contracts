// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {IIdentity} from "../src/interfaces/IIdentity.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {IReceiptRegistry} from "../src/interfaces/IReceiptRegistry.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockEscrowTasks} from "./mocks/MockEscrowTasks.sol";

/// Issue #16: a transferred agent must not keep the seller's runtime key, or the seller could sign receipts
/// (including false ones that slash the buyer's stake) for the buyer's tasks.
contract IdentityTransferTest is Test {
    bytes32 constant TYPEHASH =
        keccak256("Receipt(bytes32 taskId,bytes32 root,bytes32 terminalHash,bytes32 bodyHash,uint256 costMicros)");

    Identity id;
    ReceiptRegistry reg;
    MockEscrowTasks escrow;
    uint256 sellerKey = 0xA11CE;
    uint256 buyerKey = 0xB0B;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    uint256 agentId;
    bytes32 taskId = keccak256("task");

    function setUp() public {
        id = new Identity();
        reg = new ReceiptRegistry(id);
        escrow = new MockEscrowTasks();
        reg.setEscrow(address(escrow));
        vm.prank(seller);
        agentId = id.registerAgent(vm.addr(sellerKey), "");
        escrow.setTask(taskId, agentId, IEscrow.TaskState.Locked);
    }

    function sign(uint256 pk) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mergit"),
                keccak256("0"),
                block.chainid,
                address(reg)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(TYPEHASH, taskId, bytes32("root"), bytes32("term"), bytes32("body"), 7));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function commit(bytes memory sig) internal {
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_transferClearsTheRuntimeKey() public {
        vm.expectEmit(true, false, false, true);
        emit IIdentity.RuntimeKeyChanged(agentId, address(0));
        vm.prank(seller);
        id.transferFrom(seller, buyer, agentId);
        assertEq(id.runtimeKeyOf(agentId), address(0));
        assertEq(id.operatorOf(agentId), buyer);
    }

    function test_commitSignedWithTheSellersKeyRevertsAfterTransfer() public {
        vm.prank(seller);
        id.transferFrom(seller, buyer, agentId);
        vm.expectRevert(abi.encodeWithSelector(IReceiptRegistry.BadSignature.selector, vm.addr(sellerKey), address(0)));
        commit(sign(sellerKey));
    }

    function test_buyerCommitsAfterSettingANewKey() public {
        vm.prank(seller);
        id.transferFrom(seller, buyer, agentId);
        vm.prank(buyer);
        id.setRuntimeKey(agentId, vm.addr(buyerKey));
        commit(sign(buyerKey));
        assertEq(reg.commitmentOf(taskId).agentId, agentId);
    }

    function test_sellerCannotSetTheKeyAfterTransfer() public {
        vm.prank(seller);
        id.transferFrom(seller, buyer, agentId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IIdentity.NotOperator.selector, agentId, seller));
        id.setRuntimeKey(agentId, vm.addr(sellerKey));
    }
}
