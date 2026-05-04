// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Compilar con optimizer activado, runs = 1.
// Subir Gas Limit en Deploy & Run Transactions a 30000000.

import "remix_tests.sol";
import "../src/quadraticVoting.sol";
import "../src/governanceToken.sol";
import "../src/mocks/securityMocks.sol";

// Comprueba que solo se aceptan propuestas compatibles con ERC165.
contract SecurityERC165Test {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testNonERC165ContractCannotBeProposal() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        NonERC165Proposal invalidProposal = new NonERC165Proposal();

        // Se abre la votación y se registra el contrato de test.
        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 5 * P}();

        // El contrato tiene executeProposal, pero no declara ERC165.
        try voting.addProposal("Invalid", "Does not support ERC165", 0, address(invalidProposal)) returns (uint256) {
            Assert.ok(false, "E1");
        } catch {
            Assert.ok(true, "E2");
        }
    }

    receive() external payable {}
}

// Comprueba que una propuesta externa no puede consumir gas ilimitado.
contract SecurityGasLimitTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testGasLimitProtectsMainContract() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        GasHeavyProposal malicious = new GasHeavyProposal();

        // Se crea una propuesta que consume mucho gas al ejecutarse.
        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 30 * P}();

        uint256 id = voting.addProposal("Gas", "DoS attempt", 1 * P, address(malicious));

        token.approve(address(voting), 4);

        // La ejecución falla, pero el contrato principal sigue operativo.
        try voting.stake(id, 2) {
            Assert.ok(false, "E1");
        } catch {
            Assert.equal(voting.votingOpen(), true, "E2");
        }
    }

    receive() external payable {}
}

// Comprueba la protección frente a reentrancy en sellTokens.
contract SecurityReentrancyTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testReentrancyOnSellTokensIsBlocked() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        ReentrantSeller attacker = new ReentrantSeller(voting);

        voting.openVoting{value: 20 * P}();

        // El contrato atacante se registra y compra tokens.
        attacker.joinAndBuy{value: 5 * P}();

        Assert.equal(token.balanceOf(address(attacker)), 5, "E1");

        // Al vender, su receive intenta reentrar en sellTokens.
        attacker.attemptSell(1);

        Assert.equal(token.balanceOf(address(attacker)), 4, "E2");
        Assert.equal(attacker.reentered(), true, "E3");
    }

    receive() external payable {}
}

// Comprueba que una signaling que revierte no bloquea el cierre ni los refunds.
contract SecuritySignalingFailureTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testRevertingSignalingDoesNotBlockCloseOrClaim() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);
        GovernanceToken token = GovernanceToken(voting.getERC20());
        RevertingSignalingProposal malicious = new RevertingSignalingProposal();

        // Se crea una signaling maliciosa que revierte al ejecutarse.
        voting.openVoting{value: 10 * P}();
        voting.addParticipant{value: 10 * P}();

        uint256 id = voting.addProposal("Bad signal", "Reverts on execution", 0, address(malicious));

        token.approve(address(voting), 4);
        voting.stake(id, 2);

        Assert.equal(token.balanceOf(address(this)), 6, "E1");

        // El cierre no ejecuta la signaling, por lo que no queda bloqueado.
        voting.closeVoting();

        Assert.equal(voting.votingOpen(), false, "E2");
        Assert.equal(token.balanceOf(address(this)), 6, "E3");

        // Aunque la ronda esté cerrada, una signaling pendiente todavía no es reclamable.
        Assert.equal(voting.getClaimableTokens(id, address(this)), 0, "E4");

        // La signaling se procesa bajo demanda aunque su llamada externa falle.
        voting.executeSignalingProposal(id);

        // Aunque la ejecución externa revierta, la propuesta queda procesada
        // y los tokens ya se pueden reclamar.
        Assert.equal(voting.getClaimableTokens(id, address(this)), 4, "E4b");

        voting.claimRefundFromProposal(id);

        Assert.equal(token.balanceOf(address(this)), 10, "E5");
        Assert.equal(voting.getClaimableTokens(id, address(this)), 0, "E6");
    }

    receive() external payable {}
}

// Comprueba que no se acepta Ether enviado directamente al contrato.
contract SecurityDirectEtherTest {
    uint256 constant P = 1 gwei;

    /// #value: 1000000000000
    function testDirectEtherIsRejected() public payable {
        QuadraticVoting voting = new QuadraticVoting(P, 1000);

        // El receive de QuadraticVoting revierte para evitar Ether no contabilizado.
        (bool success, ) = address(voting).call{value: P}("");

        Assert.equal(success, false, "E1");
        Assert.equal(address(voting).balance, 0, "E2");
    }

    receive() external payable {}
}