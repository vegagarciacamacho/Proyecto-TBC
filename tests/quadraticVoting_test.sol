// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// IMPORTANTE PARA REMIX:
// Este archivo contiene pruebas pequeñas para que el contrato de test no supere
// el límite de tamaño de bytecode. Compilar con optimizer activado, runs = 200.

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";


contract QuadraticVotingLiteTest {
    uint256 constant P = 1 gwei;
    uint256 constant M = 1000;

    function testConstructorOpenAndJoin() public {
        QuadraticVoting v = new QuadraticVoting(P, M);
        GovernanceToken t = GovernanceToken(v.getERC20());

        Assert.equal(v.tokenPriceWei(), P, "E1");
        Assert.equal(t.maxSupply(), M, "E2");
        Assert.equal(v.votingOpen(), false, "E3");

        v.openVoting{value: 10 * P}();
        v.addParticipant{value: 5 * P}();

        Assert.equal(v.votingOpen(), true, "E4");
        Assert.equal(v.totalBudget(), 10 * P, "E5");
        Assert.equal(v.isParticipant(address(this)), true, "E6");
        Assert.equal(t.balanceOf(address(this)), 5, "E7");
    }

    receive() external payable {}
}

contract TestProposal is IExecutableProposal, ERC165 {
    uint256 public executions;
    uint256 public lastId;
    uint256 public lastVotes;
    uint256 public lastTokens;
    uint256 public lastValue;

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256 proposalId, uint256 numVotes, uint256 numTokens)
        external
        payable
        override
    {
        executions += 1;
        lastId = proposalId;
        lastVotes = numVotes;
        lastTokens = numTokens;
        lastValue = msg.value;
    }

    receive() external payable {}
}

contract QVStakeWithdrawExtraTest {
    uint256 constant P = 1 gwei;

    function testStakeAndWithdrawQuadraticCost() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 30 * P}();
        v.addParticipant{value: 20 * P}();

        uint256 id = v.addProposal("Q", "D", 0, address(p));

        t.approve(address(v), 16);
        v.stake(id, 4);
        Assert.equal(t.balanceOf(address(this)), 4, "E1");

        v.withdrawFromProposal(id, 2);
        Assert.equal(t.balanceOf(address(this)), 16, "E2");

        (, , , , , uint256 votes, uint256 staked, , ) = v.getProposalInfo(id);
        Assert.equal(votes, 2, "E3");
        Assert.equal(staked, 4, "E4");
    }

    receive() external payable {}
}

contract QVFundingApprovalExtraTest {
    uint256 constant P = 1 gwei;

    function testFundingProposalApprovalAndBudget() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        uint256 id = v.addProposal("F", "D", 1 * P, address(p));
        t.approve(address(v), 4);
        v.stake(id, 2);

        uint256[] memory approved = v.getApprovedProposals();
        Assert.equal(approved.length, 1, "E1");
        Assert.equal(approved[0], id, "E2");

        (, , , , QuadraticVoting.ProposalStatus status, uint256 votes, uint256 staked, , ) = v.getProposalInfo(id);
        Assert.equal(uint256(status), uint256(QuadraticVoting.ProposalStatus.Approved), "E3");
        Assert.equal(votes, 2, "E4");
        Assert.equal(staked, 4, "E5");
        Assert.equal(v.totalBudget(), 23 * P, "E6");
        Assert.equal(t.balanceOf(address(v)), 0, "E7");
        Assert.equal(p.executions(), 1, "E8");
        Assert.equal(p.lastValue(), 1 * P, "E9");
    }

    receive() external payable {}
}

contract QVInsufficientBudgetExtraTest {
    uint256 constant P = 1 gwei;

    function testInsufficientBudgetKeepsPendingAndCloseRefunds() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 5 * P}();
        v.addParticipant{value: 10 * P}();

        uint256 id = v.addProposal("X", "D", 10 * P, address(p));
        t.approve(address(v), 4);
        v.stake(id, 2);

        (, , , , QuadraticVoting.ProposalStatus status, , uint256 staked, , ) = v.getProposalInfo(id);
        Assert.equal(uint256(status), uint256(QuadraticVoting.ProposalStatus.Pending), "E1");
        Assert.equal(staked, 4, "E2");
        Assert.equal(t.balanceOf(address(this)), 6, "E3");

        v.closeVoting();
        Assert.equal(t.balanceOf(address(this)), 6, "E4");
        Assert.equal(v.getClaimableTokens(id, address(this)), 4, "E5");
        v.claimRefundFromProposal(id);
        Assert.equal(t.balanceOf(address(this)), 10, "E6");
        Assert.equal(v.votingOpen(), false, "E7");
    }

    receive() external payable {}
}

contract QVCancelSignalingExtraTest {
    uint256 constant P = 1 gwei;

    function testCanceledSignalingIsRefundedAndNotExecuted() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        uint256 id = v.addProposal("S", "D", 0, address(p));
        t.approve(address(v), 4);
        v.stake(id, 2);
        Assert.equal(t.balanceOf(address(this)), 6, "E1");

        v.cancelProposal(id);
        Assert.equal(t.balanceOf(address(this)), 6, "E2");
        Assert.equal(v.getClaimableTokens(id, address(this)), 4, "E3");
        v.claimRefundFromProposal(id);
        Assert.equal(t.balanceOf(address(this)), 10, "E4");

        uint256[] memory sig = v.getSignalingProposals();
        Assert.equal(sig.length, 0, "E5");

        v.closeVoting();
        Assert.equal(p.executions(), 0, "E6");
    }

    receive() external payable {}
}

contract QVSignalingCloseExtraTest {
    uint256 constant P = 1 gwei;

    function testSignalingExecutesOnCloseAndIdsKeepGrowing() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 50 * P}();
        v.addParticipant{value: 16 * P}();

        uint256 id1 = v.addProposal("S", "D", 0, address(p));
        t.approve(address(v), 9);
        v.stake(id1, 3);
        Assert.equal(t.balanceOf(address(this)), 7, "E1");

        v.closeVoting();
        Assert.equal(t.balanceOf(address(this)), 7, "E2");
        Assert.equal(p.executions(), 0, "E3");
        Assert.equal(v.totalBudget(), 0, "E4");

        v.executeSignalingProposal(id1);
        Assert.equal(p.executions(), 1, "E5");
        Assert.equal(v.getClaimableTokens(id1, address(this)), 9, "E6");
        v.claimRefundFromProposal(id1);
        Assert.equal(t.balanceOf(address(this)), 16, "E7");

        v.openVoting{value: 5 * P}();
        uint256 id2 = v.addProposal("N", "D", 0, address(p));
        Assert.ok(id2 != id1, "E8");
    }

    receive() external payable {}
}

contract QVPullOverPushAfterReopenExtraTest {
    uint256 constant P = 1 gwei;

    function testOldRefundAndSignalingCanBePulledAfterNewRoundOpens() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();
        uint256 oldId = v.addProposal("S", "D", 0, address(p));
        t.approve(address(v), 4);
        v.stake(oldId, 2);
        Assert.equal(t.balanceOf(address(this)), 6, "E1");

        v.closeVoting();
        v.openVoting{value: 20 * P}();

        v.executeSignalingProposal(oldId);
        Assert.equal(p.executions(), 1, "E2");
        v.claimRefundFromProposal(oldId);
        Assert.equal(t.balanceOf(address(this)), 10, "E3");
        Assert.equal(v.votingOpen(), true, "E4");
    }

    receive() external payable {}
}

contract QVSecondRoundExtraTest {
    uint256 constant P = 1 gwei;

    function testSecondRoundDoesNotReuseOldVotes() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 16 * P}();

        uint256 id1 = v.addProposal("F", "D", 1 * P, address(p));
        t.approve(address(v), 4);
        v.stake(id1, 2);

        (, , , , QuadraticVoting.ProposalStatus status, , , , ) = v.getProposalInfo(id1);
        Assert.equal(uint256(status), uint256(QuadraticVoting.ProposalStatus.Approved), "E1");
        Assert.equal(t.balanceOf(address(this)), 12, "E2");

        v.closeVoting();
        v.openVoting{value: 20 * P}();

        uint256 id2 = v.addProposal("S", "D", 0, address(p));
        Assert.ok(id2 != id1, "E3");

        t.approve(address(v), 1);
        v.stake(id2, 1);
        Assert.equal(t.balanceOf(address(this)), 11, "E4");
    }

    receive() external payable {}
}

contract QVRemovedParticipantExtraTest {
    uint256 constant P = 1 gwei;

    function testRemovedParticipantCannotActButCanWithdrawOldVotes() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        TestProposal p = new TestProposal();

        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        uint256 id = v.addProposal("S", "D", 0, address(p));
        t.approve(address(v), 9);
        v.stake(id, 3);
        Assert.equal(t.balanceOf(address(this)), 1, "E1");

        v.removeParticipant();
        Assert.equal(v.isParticipant(address(this)), false, "E2");

        try this.tryStake(v, id) {
            Assert.ok(false, "E3");
        } catch {
            Assert.ok(true, "E4");
        }

        try this.tryAddProposal(v, address(p)) returns (uint256) {
            Assert.ok(false, "E5");
        } catch {
            Assert.ok(true, "E6");
        }

        try this.tryBuy{value: P}(v) {
            Assert.ok(false, "E7");
        } catch {
            Assert.ok(true, "E8");
        }

        v.withdrawFromProposal(id, 2);
        Assert.equal(t.balanceOf(address(this)), 9, "E9");
    }

    function tryStake(QuadraticVoting v, uint256 id) external {
        v.stake(id, 1);
    }

    function tryAddProposal(QuadraticVoting v, address p) external returns (uint256) {
        return v.addProposal("X", "D", 0, p);
    }

    function tryBuy(QuadraticVoting v) external payable {
        v.buyTokens{value: msg.value}();
    }

    receive() external payable {}
}

contract QVNonOwnerActor {
    function open(QuadraticVoting v) external payable {
        v.openVoting{value: msg.value}();
    }

    function close(QuadraticVoting v) external {
        v.closeVoting();
    }

    receive() external payable {}
}

contract QVOwnerPermissionsExtraTest {
    uint256 constant P = 1 gwei;

    function testOnlyOwnerCanOpenAndCloseVoting() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        QVNonOwnerActor attacker = new QVNonOwnerActor();

        try attacker.open{value: 10 * P}(v) {
            Assert.ok(false, "E1");
        } catch {
            Assert.ok(true, "E2");
        }

        Assert.equal(v.votingOpen(), false, "E3");

        v.openVoting{value: 10 * P}();

        Assert.equal(v.votingOpen(), true, "E4");

        try attacker.close(v) {
            Assert.ok(false, "E5");
        } catch {
            Assert.ok(true, "E6");
        }

        Assert.equal(v.votingOpen(), true, "E7");

        v.closeVoting();

        Assert.equal(v.votingOpen(), false, "E8");
    }

    receive() external payable {}
}

contract QVBuyTokensExtraTest {
    uint256 constant P = 1 gwei;

    function testBuyTokensAfterJoining() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());

        v.openVoting{value: 10 * P}();

        v.addParticipant{value: 2 * P}();

        Assert.equal(v.isParticipant(address(this)), true, "E1");
        Assert.equal(t.balanceOf(address(this)), 2, "E2");

        v.buyTokens{value: 3 * P}();

        Assert.equal(t.balanceOf(address(this)), 5, "E3");
    }

    receive() external payable {}
}

contract QVSellTokensExtraTest {
    uint256 constant P = 1 gwei;

    function testSellTokensNormally() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());

        v.openVoting{value: 10 * P}();

        v.addParticipant{value: 5 * P}();

        Assert.equal(t.balanceOf(address(this)), 5, "E1");

        uint256 balanceBefore = address(this).balance;

        v.sellTokens(2);

        Assert.equal(t.balanceOf(address(this)), 3, "E2");
        Assert.equal(address(this).balance, balanceBefore + 2 * P, "E3");
    }

    receive() external payable {}
}

contract QVClosedGettersExtraTest {
    uint256 constant P = 1 gwei;

    function testGettersRevertWhenVotingIsClosed() public {
        QuadraticVoting v = new QuadraticVoting(P, 1000);

        try v.getPendingProposals() returns (uint256[] memory) {
            Assert.ok(false, "E1");
        } catch {
            Assert.ok(true, "E2");
        }

        try v.getApprovedProposals() returns (uint256[] memory) {
            Assert.ok(false, "E3");
        } catch {
            Assert.ok(true, "E4");
        }

        try v.getSignalingProposals() returns (uint256[] memory) {
            Assert.ok(false, "E5");
        } catch {
            Assert.ok(true, "E6");
        }

        try v.getProposalInfo(0) returns (
            string memory,
            string memory,
            uint256,
            address,
            QuadraticVoting.ProposalStatus,
            uint256,
            uint256,
            address,
            bool
        ) {
            Assert.ok(false, "E7");
        } catch {
            Assert.ok(true, "E8");
        }
    }

    receive() external payable {}
}