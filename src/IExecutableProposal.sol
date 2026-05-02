// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Interfaz para propuestas externas
 * Debe soportar el estándar ERC165
 */
interface IExecutableProposal is IERC165 {
    function executeProposal(
        uint256 proposalId, 
        uint256 numVotes, 
        uint256 numTokens
    ) external payable; 
}