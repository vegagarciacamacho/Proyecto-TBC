// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "remix_tests.sol"; // Librería interna de Remix
import "../src/QuadraticVoting.sol";
import "../src/Mocks/MockProposal.sol";

contract QuadraticVotingTest {
    QuadraticVoting voting;
    MockProposal mockProp;

    // Se ejecuta antes de cada test
    function beforeAll() public {
        voting = new QuadraticVoting(1 gwei, 1000000); // 1 Gwei por token
        mockProp = new MockProposal();
    }

    function testInitialStatus() public {
        Assert.equal(voting.votingOpen(), false, "La votacion deberia empezar cerrada");
    }
    
    // Aquí añadirías funciones para probar addParticipant, stake, etc.
}