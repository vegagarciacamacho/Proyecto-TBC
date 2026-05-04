// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../quadraticVoting.sol";
import "../governanceToken.sol";
import "../IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract GasHeavyProposal is IExecutableProposal, ERC165 {
    uint256 public counter;

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256, uint256, uint256) external payable override {
        // Consume mucho gas de forma finita. La llamada desde QuadraticVoting
        // está limitada a 100000 gas, por lo que debe fallar sin colgar Remix.
        for (uint256 i = 0; i < 1000; i++) {
            counter += i + 1;
        }
    }
}

contract NonERC165Proposal {
    function executeProposal(uint256, uint256, uint256) external payable {}
}

contract RevertingSignalingProposal is IExecutableProposal, ERC165 {
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256, uint256, uint256) external payable override {
        revert("Malicious signaling revert");
    }
}

contract ReentrantSeller {
    QuadraticVoting public voting;
    GovernanceToken public token;
    bool public reentered;
    bool private attackEnabled;

    constructor(QuadraticVoting _voting) {
        voting = _voting;
        token = GovernanceToken(_voting.getERC20());
    }

    receive() external payable {
        if (attackEnabled && !reentered) {
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
        attackEnabled = true;
        voting.sellTokens(amount);
        attackEnabled = false;
    }
}