// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../quadraticVoting.sol";
import "../governanceToken.sol";
import "../IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// Propuesta maliciosa que consume mucho gas al ejecutarse.
contract GasHeavyProposal is IExecutableProposal, ERC165 {
    uint256 public counter;

    // Declara soporte ERC165 para que QuadraticVoting acepte la propuesta.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    // Intenta agotar el gas disponible durante la ejecución externa.
    function executeProposal(uint256, uint256, uint256) external payable override {
        // Consume mucho gas de forma finita. La llamada desde QuadraticVoting
        // está limitada a 100000 gas, por lo que debe fallar sin colgar Remix.
        for (uint256 i = 0; i < 1000; i++) {
            counter += i + 1;
        }
    }
}

// Contrato usado para probar que se rechazan propuestas sin ERC165.
contract NonERC165Proposal {
    function executeProposal(uint256, uint256, uint256) external payable {}
}

// Propuesta de signaling que revierte al ejecutarse.
contract RevertingSignalingProposal is IExecutableProposal, ERC165 {
    // Declara soporte de IExecutableProposal mediante ERC165.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId || super.supportsInterface(interfaceId);
    }

    // Simula una propuesta externa maliciosa o defectuosa.
    function executeProposal(uint256, uint256, uint256) external payable override {
        revert("Malicious signaling revert");
    }
}

// Contrato atacante que intenta reentrar durante sellTokens.
contract ReentrantSeller {
    QuadraticVoting public voting;
    GovernanceToken public token;
    bool public reentered;
    bool private attackEnabled;

    // Guarda la referencia al sistema de votación y a su token ERC20.
    constructor(QuadraticVoting _voting) {
        voting = _voting;
        token = GovernanceToken(_voting.getERC20());
    }

    // Al recibir Ether, intenta volver a llamar a sellTokens.
    receive() external payable {
        if (attackEnabled && !reentered) {
            reentered = true;

            try voting.sellTokens(1) {
            } catch {
            }
        }
    }

    // Registra el contrato atacante como participante y compra tokens.
    function joinAndBuy() external payable {
        voting.addParticipant{value: msg.value}();
    }

    // Activa el ataque durante la venta de tokens.
    function attemptSell(uint256 amount) external {
        attackEnabled = true;
        voting.sellTokens(amount);
        attackEnabled = false;
    }
}