// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title MockProposal
 * @dev Contrato auxiliar usado en pruebas.
 *
 * Simula un contrato externo de propuesta compatible con el sistema
 * QuadraticVoting. Su objetivo es comprobar que el contrato principal:
 * - detecta correctamente la interfaz IExecutableProposal mediante ERC165;
 * - llama a executeProposal cuando una propuesta se ejecuta;
 * - transfiere correctamente Ether en propuestas de financiación.
 */
contract MockProposal is IExecutableProposal, ERC165 {
    /**
     * @dev Evento emitido cada vez que QuadraticVoting ejecuta esta propuesta.
     *
     * fundsReceived permite comprobar cuánto Ether se ha enviado en la llamada.
     * currentBalance permite verificar el saldo acumulado del contrato tras recibir fondos.
     */
    event ProposalExecuted(
        uint256 proposalId,
        uint256 numVotes,
        uint256 numTokens,
        uint256 fundsReceived,
        uint256 currentBalance
    );

    /**
     * @dev Declara compatibilidad con IExecutableProposal usando ERC165.
     *
     * QuadraticVoting usa esta función antes de aceptar una propuesta,
     * evitando añadir contratos que no implementen la interfaz requerida.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Función llamada por QuadraticVoting al ejecutar una propuesta.
     *
     * No contiene lógica real de negocio: solo emite un evento con los datos
     * recibidos para facilitar las pruebas y verificar la transferencia de Ether.
     */
    function executeProposal(uint256 proposalId, uint256 numVotes, uint256 numTokens) external payable override {
        emit ProposalExecuted(proposalId, numVotes, numTokens, msg.value, address(this).balance);
    }

    /**
     * @dev Permite que el contrato pueda recibir Ether directamente.
     *
     * En las pruebas sirve para comprobar el saldo recibido por la propuesta.
     */
    receive() external payable {}
}