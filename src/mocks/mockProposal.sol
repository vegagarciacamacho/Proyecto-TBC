// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MockProposal is IExecutableProposal, ERC165 {
    event ProposalExecuted(uint256 proposalId, uint256 numVotes, uint256 numTokens, uint256 fundsReceived, uint256 currentBalance);

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256 proposalId, uint256 numVotes, uint256 numTokens) external payable override {
        emit ProposalExecuted(proposalId, numVotes, numTokens, msg.value, address(this).balance);
    }

    receive() external payable {}
}
