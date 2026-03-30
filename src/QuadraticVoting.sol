// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GovernanceToken.sol";
import "./IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

contract QuadraticVoting {
    using ERC165Checker for address;

    // --- Eventos para Trazabilidad ---
    event VotingOpened(uint256 initialBudget); [cite: 58, 83]
    event ParticipantAdded(address indexed participant, uint256 tokensBought); [cite: 85, 87]
    event ProposalCreated(uint256 indexed id, string title, uint256 budget); [cite: 91, 93]
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint256 votes, uint256 cost); [cite: 111, 113]
    event ProposalApproved(uint256 indexed id, uint256 fundsSent); [cite: 56, 57]

    // --- Estado del Contrato ---
    address public owner;
    GovernanceToken public token;
    uint256 public tokenPriceWei;
    uint256 public totalBudget; // Presupuesto gestionado dinámicamente 
    bool public votingOpen;
    
    uint256 public numParticipants;
    uint256 public numPendingProposals;
    uint256 private nextProposalId;

    enum ProposalStatus { Pending, Approved, Canceled }

    struct Proposal {
        string title;
        uint256 requiredBudget;
        address executableContract;
        ProposalStatus status;
        uint256 totalVotes;
        uint256 totalTokensStaked;
        address creator;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public votesPerUser; // Votos acumulados para coste cuadrático [cite: 34, 113]
    mapping(address => bool) public isParticipant;

    constructor(uint256 _tokenPriceWei, uint256 _maxTokens) {
        owner = msg.sender; [cite: 23, 82]
        tokenPriceWei = _tokenPriceWei; [cite: 79]
        token = new GovernanceToken("DAO Token", "DVT"); [cite: 80]
    }

    // --- Funciones del Punto 2.2 ---

    function openVoting() external payable {
        require(msg.sender == owner, "Solo el creador puede abrir"); [cite: 23, 82]
        votingOpen = true;
        totalBudget += msg.value; [cite: 25, 83]
        emit VotingOpened(msg.value);
    }

    function addParticipant() external payable {
        require(!isParticipant[msg.sender], "Ya es participante");
        require(msg.value >= tokenPriceWei, "Debe comprar al menos un token para inscribirse"); // 

        isParticipant[msg.sender] = true;
        numParticipants++;

        uint256 amount = msg.value / tokenPriceWei;
        token.mint(msg.sender, amount); // [cite: 88]
        
        emit ParticipantAdded(msg.sender, amount);
    }

    function addProposal(string memory _title, uint256 _budget, address _exec) external returns (uint256) {
        require(votingOpen, "La votacion no esta abierta"); [cite: 91]
        require(isParticipant[msg.sender], "Solo participantes"); [cite: 91]
        
        // Verificación ERC165 
        require(_exec.supportsInterface(type(IExecutableProposal).interfaceId), "Interfaz no soportada");

        uint256 id = nextProposalId++;
        proposals[id] = Proposal(_title, _budget, _exec, ProposalStatus.Pending, 0, 0, msg.sender);
        
        if (_budget > 0) numPendingProposals++; [cite: 52]
        
        emit ProposalCreated(id, _title, _budget);
        return id; [cite: 93]
    }

    function stake(uint256 _propId, uint256 _numVotes) external {
        require(votingOpen, "Votacion cerrada");
        Proposal storage p = proposals[_propId];
        require(p.status == ProposalStatus.Pending, "Propuesta no activa");

        uint256 votesBefore = votesPerUser[_propId][msg.sender];
        uint256 votesAfter = votesBefore + _numVotes;
        
        // Lógica Cuadrática: coste = (votos_finales^2 - votos_iniciales^2) [cite: 14, 34, 35, 113]
        uint256 costInTokens = (votesAfter**2) - (votesBefore**2);
        
        // Transferencia de tokens al contrato [cite: 114, 115]
        require(token.transferFrom(msg.sender, address(this), costInTokens), "Fallo en transferencia de tokens");

        votesPerUser[_propId][msg.sender] = votesAfter;
        p.totalVotes += _numVotes;
        p.totalTokensStaked += costInTokens;

        emit VoteCast(_propId, msg.sender, _numVotes, costInTokens);

        if (p.requiredBudget > 0) {
            _checkAndExecuteProposal(_propId);
        }
    }

    function _checkAndExecuteProposal(uint256 _id) internal {
        Proposal storage p = proposals[_id];
        
        // Cálculo del umbral (Threshold) [cite: 45, 46, 47, 48]
        // threshold = (0.2 + budget/totalBudget) * (participants + pendingProposals)
        uint256 threshold = ((2 * (numParticipants + numPendingProposals)) / 10) + 
                          ((p.requiredBudget * (numParticipants + numPendingProposals)) / totalBudget);

        if (p.totalVotes > threshold && totalBudget >= p.requiredBudget) { [cite: 44, 45, 121]
            p.status = ProposalStatus.Approved;
            numPendingProposals--;

            // Ajuste de presupuesto dinámico [cite: 26, 30, 84, 123]
            totalBudget += (p.totalTokensStaked * tokenPriceWei); // Los tokens se vuelven Ether para el presupuesto
            totalBudget -= p.requiredBudget; // Se resta el coste de ejecución

            token.burn(address(this), p.totalTokensStaked); [cite: 124, 153]

            // Ejecución segura (call con límite de gas) [cite: 126, 127, 166, 168]
            (bool success, ) = p.executableContract.call{value: p.requiredBudget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", _id, p.totalVotes, p.totalTokensStaked)
            );
            
            require(success, "Fallo en la ejecucion externa");
            emit ProposalApproved(_id, p.requiredBudget);
        }
    }

        // --- Funciones de Gestión de Tokens (Punto 2.2 y 3) ---

    /**
    * @dev Permite a un participante ya inscrito comprar más tokens.
    * Sigue el precio en Wei definido en el constructor[cite: 79, 99].
    */
    function buyTokens() external payable {
        require(isParticipant[msg.sender], "Debe inscribirse primero con addParticipant"); // [cite: 90, 99]
        require(msg.value >= tokenPriceWei, "El importe no alcanza para 1 token"); // 

        uint256 amount = msg.value / tokenPriceWei;
        token.mint(msg.sender, amount); // [cite: 88, 150]
        
        emit ParticipantAdded(msg.sender, amount); // Reutilizamos el evento para trazabilidad
    }

    /**
    * @dev Permite devolver tokens no gastados y recuperar el Ether invertido.
    * Solo se pueden devolver tokens que el usuario tenga en su balance (no los bloqueados en votos).
    */
    function sellTokens(uint256 _amount) external {
        require(isParticipant[msg.sender], "No es participante"); // [cite: 90]
        require(token.balanceOf(msg.sender) >= _amount, "No tienes suficientes tokens");

        // 1. Cálculo de la devolución: tokens * precio inicial 
        uint256 refundAmount = _amount * tokenPriceWei;

        // 2. Destrucción de los tokens (quema) [cite: 153]
        // El contrato QuadraticVoting debe tener permiso en el token para hacer esto.
        token.burn(msg.sender, _amount);

        // 3. Transferencia de Ether mediante llamada de bajo nivel (call) [cite: 166]
        // Se usa el patrón recomendado para evitar ataques o fallos por límite de gas[cite: 167, 168].
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Error al enviar Ether de vuelta");
    }


    /**
    * @dev Retira una cantidad de votos de una propuesta y devuelve los tokens correspondientes.
    * @param _propId ID de la propuesta.
    * @param _numVotes Cantidad de votos a retirar.
    */
    function withdrawFromProposal(uint256 _propId, uint256 _numVotes) external {
        Proposal storage p = proposals[_propId];
        
        // 1. Verificaciones de seguridad
        require(p.status == ProposalStatus.Pending, "Solo se pueden retirar votos de propuestas pendientes"); [cite: 117, 118]
        require(userVotesInProposal[_propId][msg.sender] >= _numVotes, "No tienes tantos votos en esta propuesta"); [cite: 117]

        uint256 votesBefore = userVotesInProposal[_propId][msg.sender];
        uint256 votesAfter = votesBefore - _numVotes;

        // 2. Cálculo del reembolso de tokens (Matemática Cuadrática Inversa)
        // Reembolso = (votos_antes^2) - (votos_despues^2)
        uint256 tokensToReturn = (votesBefore * votesBefore) - (votesAfter * votesAfter); 

        // 3. Actualización de estado
        userVotesInProposal[_propId][msg.sender] = votesAfter;
        p.totalVotes -= _numVotes;
        p.totalTokensStaked -= tokensToReturn;

        // 4. Devolución de los tokens al usuario
        require(token.transfer(msg.sender, tokensToReturn), "Error al devolver tokens"); 
    }


    /**
    * @dev Cierra el periodo de votación y procesa las propuestas restantes.
    * Solo puede ser ejecutada por el propietario[cite: 128].
    */
    function closeVoting() external {
        require(msg.sender == owner, "Solo el owner puede cerrar la votacion [cite: 128]");
        require(votingOpen, "La votacion ya esta cerrada");

        votingOpen = false; // Bloquea nuevas propuestas y votos 

        // Iteramos sobre todas las propuestas creadas [cite: 134]
        for (uint256 i = 0; i < nextProposalId; i++) {
            Proposal storage p = proposals[i];

            if (p.isSignaling) {
                // 1. Ejecutar propuestas de signaling [cite: 131]
                (bool success, ) = p.executableContract.call{gas: 100000}(
                    abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", 
                    i, p.totalVotes, p.totalTokensStaked)
                );
                // Nota: No revertimos si falla el signaling para no bloquear el cierre [cite: 126]
                
                // 2. Devolver tokens de signaling a sus propietarios [cite: 131]
                _returnTokensToVoters(i);
                
            } else if (p.status == ProposalStatus.Pending) {
                // 3. Descartar propuestas de financiación no aprobadas 
                p.status = ProposalStatus.Canceled;
                numPendingProposals--;
                
                // 4. Devolver tokens de propuestas descartadas 
                _returnTokensToVoters(i);
            }
        }

        // 5. Transferir presupuesto sobrante al propietario 
        uint256 remainingBudget = totalBudget;
        totalBudget = 0;
        if (remainingBudget > 0) {
            (bool success, ) = owner.call{value: remainingBudget}("");
            require(success, "Fallo al transferir presupuesto sobrante ");
        }
        
        // El contrato queda listo para una nueva apertura 
    }

    /**
    * @dev Función auxiliar interna para devolver tokens a los votantes de una propuesta.
    * @param _propId ID de la propuesta.
    */
    function _returnTokensToVoters(uint256 _propId) internal {
        address[] storage voters = proposalVoters[_propId];
        for (uint256 j = 0; j < voters.length; j++) {
            address voter = voters[j];
            uint256 votes = userVotesInProposal[_propId][voter];
            if (votes > 0) {
                uint256 tokensToReturn = votes * votes; // n votos = n^2 tokens [cite: 35]
                userVotesInProposal[_propId][voter] = 0;
                token.transfer(voter, tokensToReturn);
            }
        }
    }
}