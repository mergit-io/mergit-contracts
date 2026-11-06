// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {Escrow} from "../src/Escrow.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {ChallengeManager} from "../src/ChallengeManager.sol";
import {ReputationAnchor} from "../src/ReputationAnchor.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IStakeVault} from "../src/interfaces/IStakeVault.sol";
import {IChallengeManager} from "../src/interfaces/IChallengeManager.sol";
import {IReputationAnchor} from "../src/interfaces/IReputationAnchor.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Shared setup for Stake, ChallengeManager and ReputationAnchor tests.
abstract contract StakeBase is Test {
    uint64 constant WINDOW = 600;
    bytes32 constant PLAN = keccak256("plan");
    uint256 constant V = 2e6;
    uint256 constant S = 3e6; // stake per task: 1.5 x V
    bytes32 constant PHI = keccak256("approved predicate");

    MockUSDC usdc;
    Identity id;
    ReceiptRegistry reg;
    Escrow escrow;
    StakeVault vault;
    ChallengeManager cm;
    ReputationAnchor anchor;

    uint256 runtimePk = 0xA11CE;
    address requester = makeAddr("requester");
    address operator = makeAddr("operator");
    address challenger = makeAddr("challenger");
    address gateway = makeAddr("gateway");
    address validator = makeAddr("validator");
    address adjudicator = makeAddr("adjudicator");
    address reserve = makeAddr("reserve");
    uint256 agentId;

    function setUp() public virtual {
        usdc = new MockUSDC();
        id = new Identity();
        reg = new ReceiptRegistry(id);
        escrow = new Escrow(usdc, id, WINDOW);
        vault = new StakeVault(usdc, 5);
        anchor = new ReputationAnchor();
        cm = new ChallengeManager(usdc, escrow, reg, vault, anchor, reserve);
        reg.setEscrow(address(escrow));
        escrow.setRegistry(address(reg));
        escrow.setStakeVault(address(vault));
        escrow.grantRole(escrow.GATEWAY_ROLE(), gateway);
        escrow.grantRole(escrow.VALIDATOR_ROLE(), validator);
        escrow.grantRole(escrow.CHALLENGE_ROLE(), address(cm));
        vault.grantRole(vault.ESCROW_ROLE(), address(escrow));
        vault.grantRole(vault.SLASHER_ROLE(), address(escrow));
        vault.grantRole(vault.SLASHER_ROLE(), address(cm));
        vault.grantRole(vault.HOLD_ROLE(), address(cm));
        vault.setReserve(reserve);
        anchor.grantRole(anchor.RECORDER_ROLE(), validator);
        anchor.grantRole(anchor.RECORDER_ROLE(), address(cm));
        cm.grantRole(cm.ADJUDICATOR_ROLE(), adjudicator);

        vm.prank(operator);
        agentId = id.registerAgent(vm.addr(runtimePk), "");
        for (uint256 i = 0; i < 3; i++) {
            address who = [requester, operator, challenger][i];
            usdc.mint(who, 100e6);
            vm.prank(who);
            usdc.approve(address(i == 1 ? address(vault) : i == 0 ? address(escrow) : address(cm)), type(uint256).max);
        }
        vm.prank(operator);
        vault.deposit(10e6);
        vm.prank(requester);
        escrow.fundPlan(PLAN, 20e6);
    }

    function lock(bytes32 t) internal {
        vm.prank(gateway);
        escrow.lockTask(t, PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function commit(bytes32 t) internal {
        bytes32 structHash = keccak256(
            abi.encode(reg.RECEIPT_TYPEHASH(), t, bytes32("root"), bytes32("term"), bytes32("body"), uint256(1))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mergit"),
                keccak256("0"),
                block.chainid,
                address(reg)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(runtimePk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        reg.commit(t, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 1, abi.encodePacked(r, s, v));
    }

    function verdict(bytes32 t, IEscrow.Verdict v) internal {
        vm.prank(validator);
        escrow.recordVerdict(t, v);
    }

    function available() internal view returns (uint256 a) {
        (,, a,) = escrow.planOf(PLAN);
    }
}
