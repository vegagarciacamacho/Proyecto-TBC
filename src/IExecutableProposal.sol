// SPDX-License-Identifier: MIT
锋pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Interfaz que deben implementar todas las propuestas de la DAO[cite: 61, 62].
 */
interface IExecutableProposal is IERC165 {
    /**
     * @dev Función llamada por el motor QuadraticVoting cuando se aprueba una propuesta[cite: 64, 66].
     * @param proposalId ID único de la propuesta.
     * @param numVotes Cantidad total de votos recibidos.
     * @param numTokens Cantidad de tokens (crédito) que respaldaron la propuesta.
     */
    function executeProposal(
        uint256 proposalId, 
        uint256 numVotes, 
        uint256 numTokens
    ) external payable; [cite: 64]
}