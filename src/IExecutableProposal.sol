// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Interfaz para propuestas externas[cite: 62].
 * Debe soportar el estándar ERC165[cite: 74, 75].
 */
interface IExecutableProposal is IERC165 {
    function executeProposal(
        uint256 proposalId, 
        uint256 numVotes, 
        uint256 numTokens
    ) external payable; // [cite: 64]
}