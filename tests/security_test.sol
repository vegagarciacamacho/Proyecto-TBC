// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract GasConsumerProposal is IExecutableProposal, ERC165 {
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256, uint256, uint256) external payable override {
        while (true) {}
    }
}

contract ReentrantSeller {
    QuadraticVoting public voting;
    GovernanceToken public token;
    bool public reentered;

    constructor(QuadraticVoting _voting) {
        voting = _voting;
        token = GovernanceToken(_voting.getERC20());
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try voting.sellTokens(1) {
            } catch {
            }
        }
    }

    function joinAndBuy() external payable {
        voting.addParticipant{value: msg.value}();
    }

    function attemptSell(uint256 amount) external {
        voting.sellTokens(amount);
    }
}

contract SecurityTest {
    uint256 constant TOKEN_PRICE = 1 gwei;

    function testGasLimitProtectsMainContract() public {
        QuadraticVoting voting = new QuadraticVoting(TOKEN_PRICE, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        GasConsumerProposal malicious = new GasConsumerProposal();

        voting.openVoting{value: 10 * TOKEN_PRICE}();
        voting.addParticipant{value: 30 * TOKEN_PRICE}();

        uint256 id = voting.addProposal("Gas", "DoS attempt", 1 * TOKEN_PRICE, address(malicious));
        token.approve(address(voting), 25);

        try voting.stake(id, 5) {
            Assert.ok(false, "Stake should revert because proposal execution exhausts 100k gas budget");
        } catch {
            Assert.ok(voting.votingOpen(), "Voting contract should remain alive after failed external execution");
        }
    }

    function testReentrancyOnSellTokensIsBlocked() public {
        QuadraticVoting voting = new QuadraticVoting(TOKEN_PRICE, 1000);
        ReentrantSeller attacker = new ReentrantSeller(voting);
        GovernanceToken token = GovernanceToken(voting.getERC20());

        voting.openVoting{value: 20 * TOKEN_PRICE}();
        (bool sent, ) = payable(address(attacker)).call{value: 5 * TOKEN_PRICE}("");
        require(sent, "Funding attacker failed");
        attacker.joinAndBuy{value: 5 * TOKEN_PRICE}();
        Assert.equal(token.balanceOf(address(attacker)), 5, "Attacker should own 5 tokens");

        attacker.attemptSell(1);
        Assert.equal(token.balanceOf(address(attacker)), 4, "Only one token should be sold");
        Assert.ok(attacker.reentered(), "Attacker fallback should have attempted reentrancy");
    }

    receive() external payable {}
}
