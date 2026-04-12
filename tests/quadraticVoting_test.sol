// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/mocks/mockProposal.sol";

contract ParticipantActor {
    receive() external payable {}

    function addParticipant(QuadraticVoting voting) external payable {
        voting.addParticipant{value: msg.value}();
    }

    function buyTokens(QuadraticVoting voting) external payable {
        voting.buyTokens{value: msg.value}();
    }

    function approveToken(GovernanceToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function addProposal(
        QuadraticVoting voting,
        string memory title,
        string memory description,
        uint256 budget,
        address exec
    ) external returns (uint256) {
        return voting.addProposal(title, description, budget, exec);
    }

    function stake(QuadraticVoting voting, uint256 proposalId, uint256 votes) external {
        voting.stake(proposalId, votes);
    }

    function withdrawFromProposal(QuadraticVoting voting, uint256 proposalId, uint256 votes) external {
        voting.withdrawFromProposal(proposalId, votes);
    }

    function cancelProposal(QuadraticVoting voting, uint256 proposalId) external {
        voting.cancelProposal(proposalId);
    }

    function sellTokens(QuadraticVoting voting, uint256 amount) external {
        voting.sellTokens(amount);
    }

    function removeParticipant(QuadraticVoting voting) external {
        voting.removeParticipant();
    }

    function tokenBalance(GovernanceToken token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract QuadraticVotingTest {
    uint256 constant TOKEN_PRICE = 1 gwei;
    uint256 constant MAX_TOKENS = 1000;

    function _setup()
        internal
        returns (
            QuadraticVoting voting,
            GovernanceToken token,
            MockProposal executable,
            ParticipantActor alice,
            ParticipantActor bob
        )
    {
        voting = new QuadraticVoting(TOKEN_PRICE, MAX_TOKENS);
        token = GovernanceToken(voting.getERC20());
        executable = new MockProposal();
        alice = new ParticipantActor();
        bob = new ParticipantActor();
    }

    function _fund(address payable to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        require(success, "Funding helper failed");
    }

    function testConstructorAndERC20Config() public {
        (QuadraticVoting voting, GovernanceToken token,,,) = _setup();
        Assert.equal(voting.tokenPriceWei(), TOKEN_PRICE, "Incorrect token price");
        Assert.equal(token.maxSupply(), MAX_TOKENS, "Incorrect cap");
        Assert.equal(voting.votingOpen(), false, "Voting should start closed");
    }

    function testOpenVotingAndParticipantLifecycle() public {
        (QuadraticVoting voting, GovernanceToken token,, ParticipantActor alice,) = _setup();
        voting.openVoting{value: 10 * TOKEN_PRICE}();
        Assert.equal(voting.totalBudget(), 10 * TOKEN_PRICE, "Initial budget mismatch");

        _fund(payable(address(alice)), 25 * TOKEN_PRICE);
        alice.addParticipant{value: 10 * TOKEN_PRICE}(voting);
        Assert.ok(voting.isParticipant(address(alice)), "Alice should be participant");
        Assert.equal(voting.numParticipants(), 1, "Participant count mismatch");
        Assert.equal(alice.tokenBalance(token), 10, "Alice token purchase mismatch");

        alice.removeParticipant(voting);
        Assert.ok(!voting.isParticipant(address(alice)), "Alice should be removed");
        Assert.equal(voting.numParticipants(), 0, "Participant count should decrease");
    }

    function testQuadraticStakeAndWithdraw() public {
        (QuadraticVoting voting, GovernanceToken token, MockProposal executable, ParticipantActor alice,) = _setup();
        voting.openVoting{value: 30 * TOKEN_PRICE}();

        _fund(payable(address(alice)), 30 * TOKEN_PRICE);
        alice.addParticipant{value: 20 * TOKEN_PRICE}(voting);
        uint256 proposalId = alice.addProposal(voting, "QV", "Quadratic cost", 25 * TOKEN_PRICE, address(executable));

        alice.approveToken(token, address(voting), 16);
        alice.stake(voting, proposalId, 4);
        Assert.equal(alice.tokenBalance(token), 4, "4 votes should cost 16 tokens");

        alice.withdrawFromProposal(voting, proposalId, 2);
        Assert.equal(alice.tokenBalance(token), 16, "Withdrawing 2 votes from 4 should refund 12 tokens");

        (, , , , , uint256 totalVotes, uint256 totalTokensStaked, , ) = voting.getProposalInfo(proposalId);
        Assert.equal(totalVotes, 2, "Votes after withdrawal mismatch");
        Assert.equal(totalTokensStaked, 4, "Staked tokens after withdrawal mismatch");
    }

    function testProposalApprovalThresholdAndBudgetUpdate() public {
        (QuadraticVoting voting, GovernanceToken token, MockProposal executable, ParticipantActor alice, ParticipantActor bob) = _setup();
        voting.openVoting{value: 20 * TOKEN_PRICE}();

        _fund(payable(address(alice)), 60 * TOKEN_PRICE);
        _fund(payable(address(bob)), 60 * TOKEN_PRICE);
        alice.addParticipant{value: 25 * TOKEN_PRICE}(voting);
        bob.addParticipant{value: 25 * TOKEN_PRICE}(voting);

        uint256 proposalId = alice.addProposal(voting, "Funded", "Funded proposal", 5 * TOKEN_PRICE, address(executable));
        uint256[] memory pending = voting.getPendingProposals();
        Assert.equal(pending.length, 1, "There should be one pending proposal");

        alice.approveToken(token, address(voting), 9);
        bob.approveToken(token, address(voting), 9);
        alice.stake(voting, proposalId, 3);
        bob.stake(voting, proposalId, 3);

        uint256[] memory approved = voting.getApprovedProposals();
        Assert.equal(approved.length, 1, "Proposal should be approved");
        Assert.equal(approved[0], proposalId, "Approved id mismatch");

        (, , , , QuadraticVoting.ProposalStatus status, uint256 totalVotes, uint256 totalTokensStaked, , ) = voting.getProposalInfo(proposalId);
        Assert.equal(uint256(status), uint256(QuadraticVoting.ProposalStatus.Approved), "Wrong status");
        Assert.equal(totalVotes, 6, "Approved vote total mismatch");
        Assert.equal(totalTokensStaked, 18, "Approved token total mismatch");
        Assert.equal(voting.totalBudget(), 33 * TOKEN_PRICE, "Budget should add 18 and subtract 5 from initial 20");
        Assert.equal(token.balanceOf(address(voting)), 0, "Consumed voting tokens should be burned");
    }

    function testCancelProposalReturnsTokens() public {
        (QuadraticVoting voting, GovernanceToken token, MockProposal executable, ParticipantActor alice,) = _setup();
        voting.openVoting{value: 10 * TOKEN_PRICE}();

        _fund(payable(address(alice)), 30 * TOKEN_PRICE);
        alice.addParticipant{value: 10 * TOKEN_PRICE}(voting);
        uint256 proposalId = alice.addProposal(voting, "Cancelable", "Desc", 9 * TOKEN_PRICE, address(executable));
        alice.approveToken(token, address(voting), 9);
        alice.stake(voting, proposalId, 3);
        Assert.equal(alice.tokenBalance(token), 1, "Alice should have 1 token left before cancel");

        alice.cancelProposal(voting, proposalId);
        Assert.equal(alice.tokenBalance(token), 10, "Cancel should return all staked tokens");
    }

    function testSignalingExecutionAndCloseResetsCycle() public {
        (QuadraticVoting voting, GovernanceToken token, MockProposal executable, ParticipantActor alice,) = _setup();
        voting.openVoting{value: 50 * TOKEN_PRICE}();

        _fund(payable(address(alice)), 30 * TOKEN_PRICE);
        alice.addParticipant{value: 16 * TOKEN_PRICE}(voting);
        uint256 signalingId = alice.addProposal(voting, "Signal", "Preference", 0, address(executable));
        uint256[] memory signaling = voting.getSignalingProposals();
        Assert.equal(signaling.length, 1, "There should be one signaling proposal");
        Assert.equal(signaling[0], signalingId, "Wrong signaling id");

        alice.approveToken(token, address(voting), 9);
        alice.stake(voting, signalingId, 3);
        Assert.equal(alice.tokenBalance(token), 7, "Alice should have 7 tokens left before close");

        uint256 ownerBefore = address(this).balance;
        voting.closeVoting();
        Assert.equal(voting.votingOpen(), false, "Voting should be closed");
        Assert.equal(voting.totalBudget(), 0, "Budget should be cleared");
        Assert.equal(alice.tokenBalance(token), 16, "Signaling votes should be refunded at close");
        Assert.ok(address(this).balance >= ownerBefore + (50 * TOKEN_PRICE), "Owner should receive remaining budget");

        voting.openVoting{value: 5 * TOKEN_PRICE}();
        uint256 newId = alice.addProposal(voting, "New cycle", "Restart ok", 0, address(executable));
        Assert.equal(newId, 0, "Proposal ids should restart after close");
    }

    receive() external payable {}
}
