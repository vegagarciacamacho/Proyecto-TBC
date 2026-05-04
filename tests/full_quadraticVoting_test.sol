// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Compilar con optimizer activado, runs = 1.
// Subir Gas Limit en Deploy & Run Transactions a 30000000.

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/mocks/mockProposal.sol";

// Prueba de integración: recorre un flujo completo de votación.
contract QVFullFlowIntegrationTest {
    uint256 constant P = 1 gwei;
    
    /// #value: 1000000000000
    function testFullVotingFlowWithPullOverPush() public payable {
        QuadraticVoting v = new QuadraticVoting(P, 1000);
        GovernanceToken t = GovernanceToken(v.getERC20());
        MockProposal p = new MockProposal();

        // Se abre una ronda y el contrato de test se registra como participante.
        v.openVoting{value: 50 * P}();
        v.addParticipant{value: 20 * P}();

        // Se crean una propuesta de financiación y una de signaling.
        uint256 fundingId = v.addProposal("F", "D", 5 * P, address(p));
        uint256 signalingId = v.addProposal("S", "D", 0, address(p));

        // Se autoriza a QuadraticVoting a mover los tokens necesarios para votar.
        t.approve(address(v), 20);

        // Se votan ambas propuestas con coste cuadrático.
        v.stake(fundingId, 3);
        v.stake(signalingId, 2);

        // La propuesta de financiación debe aprobarse automáticamente.
        uint256[] memory approved = v.getApprovedProposals();
        Assert.equal(approved.length, 1, "E1");
        Assert.equal(approved[0], fundingId, "E2");

        // El cierre no ejecuta signaling ni devuelve tokens en bucle.
        v.closeVoting();

        Assert.equal(v.votingOpen(), false, "E3");

        // Antes de ejecutar la signaling, todavía no se pueden reclamar sus tokens.
        Assert.equal(v.getClaimableTokens(signalingId, address(this)), 0, "E4");

        // La signaling se procesa bajo demanda.
        v.executeSignalingProposal(signalingId);

        // Después de procesarla, ya se pueden reclamar.
        Assert.equal(v.getClaimableTokens(signalingId, address(this)), 4, "E4b");

        // El votante recupera individualmente los tokens bloqueados.
        v.claimRefundFromProposal(signalingId);

        Assert.equal(v.getClaimableTokens(signalingId, address(this)), 0, "E5");
    }

    receive() external payable {}
}