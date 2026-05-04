// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

// Contrato de prueba que simula una propuesta externa válida.
contract MockProposal is IExecutableProposal, ERC165 {
    // Evento para comprobar que la propuesta se ha ejecutado y ha recibido fondos.
    event ProposalExecuted(
        uint256 proposalId,
        uint256 numVotes,
        uint256 numTokens,
        uint256 fundsReceived,
        uint256 currentBalance
    );

    // Declara soporte de IExecutableProposal mediante ERC165.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    // Función llamada por QuadraticVoting al ejecutar la propuesta.
    function executeProposal(uint256 proposalId, uint256 numVotes, uint256 numTokens) external payable override {
        emit ProposalExecuted(proposalId, numVotes, numTokens, msg.value, address(this).balance);
    }

    // Permite recibir Ether en las pruebas.
    receive() external payable {}
}