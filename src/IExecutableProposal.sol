// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Interfaz que deben implementar los contratos externos de propuesta.
 * Hereda de IERC165 para que QuadraticVoting pueda verificar compatibilidad.
 */
interface IExecutableProposal is IERC165 {
    // Función llamada cuando una propuesta es ejecutada por QuadraticVoting.
    function executeProposal(
        uint256 proposalId, 
        uint256 numVotes, 
        uint256 numTokens
    ) external payable; 
}