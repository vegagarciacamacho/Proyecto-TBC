// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/mocks/mockProposal.sol";

contract QVFullFlowIntegrationTest {
    uint256 constant P = 1 gwei;
    
    /// #value: 1000000000000
    function testFullVotingFlowWithPullOverPush() public payable {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        MockProposal p = new MockProposal();

        v.openVoting{value: 50 * P}();
        v.addParticipant{value: 20 * P}();

        uint256 fundingId = v.addProposal("F", "D", 5 * P, address(p));
        uint256 signalingId = v.addProposal("S", "D", 0, address(p));

        t.approve(address(v), 20);

        v.stake(fundingId, 3);
        v.stake(signalingId, 2);

        uint256[] memory approved = v.getApprovedProposals();
        Assert.equal(approved.length, 1, "E1");
        Assert.equal(approved[0], fundingId, "E2");

        v.closeVoting();

        Assert.equal(v.votingOpen(), false, "E3");
        Assert.equal(v.getClaimableTokens(signalingId, address(this)), 4, "E4");

        v.executeSignalingProposal(signalingId);
        v.claimRefundFromProposal(signalingId);

        Assert.equal(v.getClaimableTokens(signalingId, address(this)), 0, "E5");
        Assert.ok(t.balanceOf(address(this)) > 0, "E6");

        v.openVoting{value: 10 * P}();

        Assert.equal(v.votingOpen(), true, "E7");
    }

    receive() external payable {}
}