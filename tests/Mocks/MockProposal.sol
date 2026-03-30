// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../src/IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MockProposal is IExecutableProposal, ERC165 {
    event ProposalExecuted(uint256 id, uint256 funds);

    // Debe declarar que soporta la interfaz IExecutableProposal [cite: 74]
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    function executeProposal(uint256 proposalId, uint256, uint256) external payable override {
        emit ProposalExecuted(proposalId, msg.value);
    }

    // Necesario para recibir Ether mediante .call [cite: 166]
    receive() external payable {}
}