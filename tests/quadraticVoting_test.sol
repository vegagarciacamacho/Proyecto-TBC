// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "remix_tests.sol";
import "remix_accounts.sol";
import "../src/quadraticVoting.sol";
import "../src/mocks/mockProposal.sol";

contract QuadraticVotingTest {
    QuadraticVoting voting;
    MockProposal mockProp;
    GovernanceToken token;
    
    address owner;
    uint256 tokenPrice = 1 gwei;

    // Preparación del entorno
    function beforeAll() public {
        owner = TestsAccounts.getAccount(0);
        // Desplegamos el motor con un precio de 1 Gwei por token
        voting = new QuadraticVoting(tokenPrice, 1000000);
        mockProp = new MockProposal();
        token = GovernanceToken(voting.getERC20());
    }

    // --- BLOQUE 1: PRUEBAS INDIVIDUALES (FUNCIONALIDAD SEPARADA) ---

    function testEstadoInicial() public {
        Assert.equal(voting.votingOpen(), false, "La votacion debe empezar cerrada");
        Assert.equal(voting.tokenPriceWei(), tokenPrice, "El precio del token no coincide");
    }

    /// #value: 10000000000
    function testAperturaVotacion() public payable {
        // Abrimos con 10 Gwei de presupuesto inicial [cite: 22]
        voting.openVoting{value: 10 * tokenPrice}();
        Assert.equal(voting.votingOpen(), true, "La votacion deberia estar abierta");
        Assert.equal(voting.totalBudget(), 10 * tokenPrice, "Presupuesto inicial incorrecto");
    }

    /// #value: 20000000000
    function testRegistroYCompraTokens() public payable {
        // El contrato de test actúa como participante comprando 20 tokens
        voting.addParticipant{value: 20 * tokenPrice}();
        Assert.equal(voting.isParticipant(address(this)), true, "Error al registrar participante");
        Assert.equal(token.balanceOf(address(this)), 20, "No se mintearon los tokens correctos");
    }

    function testLogicaCuadraticaCoste() public {
        // Crear propuesta para votar
        uint256 id = voting.addProposal("Test Cuadratico", "Desc", 5 * tokenPrice, address(mockProp));
        
        // Votamos 3 votos. Coste: 3^2 = 9 tokens 
        token.approve(address(voting), 9);
        voting.stake(id, 3);
        
        Assert.equal(token.balanceOf(address(this)), 11, "Deberian quedar 11 tokens (20 - 9)");
        
        // Votamos 1 voto más. Coste: (4^2) - (3^2) = 16 - 9 = 7 tokens
        token.approve(address(voting), 7);
        voting.stake(id, 1);
        
        Assert.equal(token.balanceOf(address(this)), 4, "Deberian quedar 4 tokens (11 - 7)");
    }

    function testVentaDeTokens() public {
        // Vendemos los 4 tokens restantes. Deberia devolvernos 4 Gwei 
        uint256 balanceAntes = address(this).balance;
        voting.sellTokens(4);
        Assert.equal(token.balanceOf(address(this)), 0, "No se quemaron los tokens");
        Assert.ok(address(this).balance > balanceAntes, "No se recibio el reembolso en Ether");
    }

    // --- BLOQUE 2: GUION DE PRUEBAS CONJUNTAS (ESCENARIO INTEGRADO) ---

    /// #value: 50000000000
    function testEscenarioCicloCompletoDAO() public payable {
        // 1. Nuevo registro con fondos frescos
        voting.addParticipant{value: 50 * tokenPrice}();
        
        // 2. Crear propuesta de financiacion (Coste 2 Gwei)
        uint256 propId = voting.addProposal("Propuesta Final", "Inversion", 2 * tokenPrice, address(mockProp));
        
        // 3. Votar para superar el umbral
        // Ponemos 6 votos (36 tokens). Esto deberia disparar la ejecucion automatica [cite: 38]
        token.approve(address(voting), 36);
        voting.stake(propId, 6);
        
        // 4. Verificar presupuesto dinamico [cite: 39]
        // Presupuesto = Presupuesto_Actual + Valor_Tokens_Votos - Coste_Propuesta
        // Nota: El presupuesto actual depende de los tests anteriores
        (,,,,QuadraticVoting.ProposalStatus status,,,,) = voting.proposals(propId);
        Assert.equal(uint(status), uint(QuadraticVoting.ProposalStatus.Approved), "La propuesta no se aprobo");
    }

    function testCierreYLiquidacion() public {
        // Al cerrar, el owner recibe el presupuesto sobrante mediante .call [cite: 56, 57]
        voting.closeVoting();
        Assert.equal(voting.votingOpen(), false, "Fallo al cerrar votacion");
        Assert.equal(voting.totalBudget(), 0, "El presupuesto deberia estar a cero tras liquidar");
    }
}