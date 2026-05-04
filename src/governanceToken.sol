// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Token ERC20 usado como token de voto en QuadraticVoting.
contract GovernanceToken is ERC20 {
    address public immutable votingContract;
    uint256 public immutable maxSupply;

    // Solo el contrato de votación puede crear o destruir tokens.
    modifier onlyVoting() {
        require(msg.sender == votingContract, "Only voting contract");
        _;
    }

    // El contrato que despliega el token queda fijado como contrato de votación.
    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply
    ) ERC20(name, symbol) {
        require(_maxSupply > 0, "Max supply must be > 0");
        votingContract = msg.sender;
        maxSupply = _maxSupply;
    }

    // Crea tokens para participantes al registrarse o comprar tokens.
    function mint(address to, uint256 amount) external onlyVoting {
        require(totalSupply() + amount <= maxSupply, "Max token supply exceeded");
        _mint(to, amount);
    }

    // Elimina tokens vendidos o consumidos por propuestas aprobadas.
    function burn(address from, uint256 amount) external onlyVoting {
        _burn(from, amount);
    }

    // No se usan decimales: 1 unidad equivale a 1 token de voto.
    function decimals() public pure override returns (uint8) {
        return 0;
    }
}