// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// IMPORTANTE PARA REMIX:
// Compilar con optimizer activado, runs = 1.
// Subir Gas Limit en Deploy & Run Transactions a 30000000.

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/mocks/securityMocks.sol";

contract SecurityERC165Test {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testNonERC165ContractCannotBeProposal() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        NonERC165Proposal invalidProposal = new NonERC165Proposal();

        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 5 * P}();

        try voting.addProposal("Invalid", "Does not support ERC165", 0, address(invalidProposal)) returns (uint256) {
            Assert.ok(false, "E1");
        } catch {
            Assert.ok(true, "E2");
        }
    }

    receive() external payable {}
}

contract SecurityGasLimitTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testGasLimitProtectsMainContract() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        GasHeavyProposal malicious = new GasHeavyProposal();

        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 30 * P}();

        uint256 id = voting.addProposal("Gas", "DoS attempt", 1 * P, address(malicious));

        token.approve(address(voting), 4);

        try voting.stake(id, 2) {
            Assert.ok(false, "E1");
        } catch {
            Assert.equal(voting.votingOpen(), true, "E2");
        }
    }

    receive() external payable {}
}

contract SecurityReentrancyTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testReentrancyOnSellTokensIsBlocked() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        ReentrantSeller attacker = new ReentrantSeller(voting);

        voting.openVoting{value: 20 * P}();

        attacker.joinAndBuy{value: 5 * P}();

        Assert.equal(token.balanceOf(address(attacker)), 5, "E1");

        attacker.attemptSell(1);

        Assert.equal(token.balanceOf(address(attacker)), 4, "E2");
        Assert.equal(attacker.reentered(), true, "E3");
    }

    receive() external payable {}
}

contract SecuritySignalingFailureTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testRevertingSignalingDoesNotBlockCloseOrClaim() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        RevertingSignalingProposal malicious = new RevertingSignalingProposal();

        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 10 * P}();

        uint256 id = voting.addProposal("Bad signal", "Reverts on execution", 0, address(malicious));

        token.approve(address(voting), 4);
        voting.stake(id, 2);

        Assert.equal(token.balanceOf(address(this)), 6, "E1");

        voting.closeVoting();

        Assert.equal(voting.votingOpen(), false, "E2");
        Assert.equal(token.balanceOf(address(this)), 6, "E3");
        Assert.equal(voting.getClaimableTokens(id, address(this)), 4, "E4");

        voting.executeSignalingProposal(id);
        voting.claimRefundFromProposal(id);

        Assert.equal(token.balanceOf(address(this)), 10, "E5");
        Assert.equal(voting.getClaimableTokens(id, address(this)), 0, "E6");
    }

    receive() external payable {}
}

contract SecurityDirectEtherTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testDirectEtherIsRejected() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);

        (bool success, ) = address(voting).call{value: P}("");

        Assert.equal(success, false, "E1");
        Assert.equal(address(voting).balance, 0, "E2");
    }

    receive() external payable {}
}