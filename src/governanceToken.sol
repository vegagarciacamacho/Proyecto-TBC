// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GovernanceToken is ERC20 {
    address public votingContract;

    // Solo el contrato QuadraticVoting tiene permiso para gestionar tokens 
    modifier onlyVoting() {
        require(msg.sender == votingContract, "No autorizado: solo el sistema de votacion");
        _;
    }

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        votingContract = msg.sender; // El motor QuadraticVoting sera el owner
    }

    // Crea nuevos tokens para los participantes
    function mint(address to, uint256 amount) external onlyVoting {
        _mint(to, amount);
    }

    // Elimina tokens cuando una propuesta se aprueba o se venden tokens 
    function burn(address from, uint256 amount) external onlyVoting {
        _burn(from, amount);
    }
}