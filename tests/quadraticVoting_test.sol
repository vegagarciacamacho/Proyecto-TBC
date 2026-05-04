// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// IMPORTANTE PARA REMIX:
// Compilar con optimizer activado, runs = 1.
// Subir Gas Limit en Deploy & Run Transactions a 30000000.

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/mocks/mockProposal.sol";

contract QVTokenFlowTest {
    uint256 constant P = 1 gwei;

    QuadraticVoting v;
    GovernanceToken t;

    function beforeAll() public {
        v = new QuadraticVoting(P, 1000);
        t = GovernanceToken(v.getERC20());
    }

    function test01Constructor() public {
        Assert.equal(v.tokenPriceWei(), P, "E1");
        Assert.equal(t.maxSupply(), 1000, "E2");
        Assert.equal(v.votingOpen(), false, "E3");
    }

    /// #value: 1000000000000
    function test02OpenVoting() public payable {
        v.openVoting{value: 10 * P}();

        Assert.equal(v.votingOpen(), true, "E4");
        Assert.equal(v.totalBudget(), 10 * P, "E5");
    }

    function test03AddParticipant() public {
        v.addParticipant{value: 5 * P}();

        Assert.equal(v.isParticipant(address(this)), true, "E6");
        Assert.equal(t.balanceOf(address(this)), 5, "E7");
    }

    function test04BuyTokens() public {
        v.buyTokens{value: 3 * P}();

        Assert.equal(t.balanceOf(address(this)), 8, "E8");
    }

    function test05SellTokens() public {
        v.sellTokens(2);

        Assert.equal(t.balanceOf(address(this)), 6, "E9");
    }

    receive() external payable {}
}

contract QVSignalingStakeWithdrawTest {
    uint256 constant P = 1 gwei;

    QuadraticVoting v;
    GovernanceToken t;
    MockProposal p;
    uint256 proposalId;

    function beforeAll() public {
        v = new QuadraticVoting(P, 1000);
        t = GovernanceToken(v.getERC20());
        p = new MockProposal();
    }

    /// #value: 1000000000000
    function test01OpenJoinAndCreateSignaling() public payable {
        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        proposalId = v.addProposal("S", "D", 0, address(p));

        uint256[] memory signaling = v.getSignalingProposals();

        Assert.equal(signaling.length, 1, "E1");
        Assert.equal(signaling[0], proposalId, "E2");
    }

    function test02StakeQuadraticVotes() public {
        t.approve(address(v), 4);
        v.stake(proposalId, 2);

        Assert.equal(t.balanceOf(address(this)), 6, "E3");

        (, , , , , uint256 votes, uint256 staked, , ) = v.getProposalInfo(proposalId);

        Assert.equal(votes, 2, "E4");
        Assert.equal(staked, 4, "E5");
    }

    function test03WithdrawVotes() public {
        v.withdrawFromProposal(proposalId, 1);

        Assert.equal(t.balanceOf(address(this)), 9, "E6");

        (, , , , , uint256 votes, uint256 staked, , ) = v.getProposalInfo(proposalId);

        Assert.equal(votes, 1, "E7");
        Assert.equal(staked, 1, "E8");
    }

    receive() external payable {}
}

contract QVFundingApprovalTest {
    uint256 constant P = 1 gwei;

    QuadraticVoting v;
    GovernanceToken t;
    MockProposal p;
    uint256 proposalId;

    function beforeAll() public {
        v = new QuadraticVoting(P, 1000);
        t = GovernanceToken(v.getERC20());
        p = new MockProposal();
    }

    /// #value: 1000000000000
    function test01OpenJoinAndCreateFundingProposal() public payable {
        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        proposalId = v.addProposal("F", "D", 1 * P, address(p));

        uint256[] memory pending = v.getPendingProposals();

        Assert.equal(pending.length, 1, "E1");
        Assert.equal(pending[0], proposalId, "E2");
    }

    function test02FundingProposalIsApproved() public {
        t.approve(address(v), 4);
        v.stake(proposalId, 2);

        uint256[] memory approved = v.getApprovedProposals();

        Assert.equal(approved.length, 1, "E3");
        Assert.equal(approved[0], proposalId, "E4");

        (, , , , QuadraticVoting.ProposalStatus status, uint256 votes, uint256 staked, , ) =
            v.getProposalInfo(proposalId);

        Assert.equal(uint256(status), uint256(QuadraticVoting.ProposalStatus.Approved), "E5");
        Assert.equal(votes, 2, "E6");
        Assert.equal(staked, 4, "E7");
        Assert.equal(v.totalBudget(), 23 * P, "E8");
    }

    receive() external payable {}
}

contract QVPullOverPushTest {
    uint256 constant P = 1 gwei;

    QuadraticVoting v;
    GovernanceToken t;
    MockProposal p;
    uint256 proposalId;

    function beforeAll() public {
        v = new QuadraticVoting(P, 1000);
        t = GovernanceToken(v.getERC20());
        p = new MockProposal();
    }

    /// #value: 1000000000000
    function test01CreateAndVoteSignaling() public payable {
        v.openVoting{value: 20 * P}();
        v.addParticipant{value: 10 * P}();

        proposalId = v.addProposal("S", "D", 0, address(p));

        t.approve(address(v), 4);
        v.stake(proposalId, 2);

        Assert.equal(t.balanceOf(address(this)), 6, "E1");
    }

    function test02CloseDoesNotRefundAutomatically() public {
        v.closeVoting();

        Assert.equal(v.votingOpen(), false, "E2");
        Assert.equal(t.balanceOf(address(this)), 6, "E3");
        Assert.equal(v.getClaimableTokens(proposalId, address(this)), 4, "E4");
    }

    function test03ExecuteSignalingAndClaimRefund() public {
        v.executeSignalingProposal(proposalId);
        v.claimRefundFromProposal(proposalId);

        Assert.equal(t.balanceOf(address(this)), 10, "E5");
    }

    function test04CanOpenNewRoundAfterClose() public {
        v.openVoting{value: 10 * P}();

        Assert.equal(v.votingOpen(), true, "E6");
    }

    receive() external payable {}
}

contract QVClosedGettersTest {
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
    }

    receive() external payable {}
}