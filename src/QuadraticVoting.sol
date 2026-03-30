// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GovernanceToken.sol";
import "./IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

contract QuadraticVoting {
    using ERC165Checker for address;

    // --- Eventos ---
    event VotingOpened(uint256 initialBudget); 
    event ParticipantAdded(address indexed participant, uint256 tokensBought); 
    event ProposalCreated(uint256 indexed id, string title, uint256 budget); 
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint256 votes, uint256 cost); 
    event ProposalApproved(uint256 indexed id, uint256 fundsSent); 

    // --- Estado del Contrato ---
    address public owner;
    GovernanceToken public token;
    uint256 public tokenPriceWei;
    uint256 public totalBudget; 
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
        bool isSignaling;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public userVotesInProposal; 
    mapping(uint256 => address[]) private proposalVoters; 
    mapping(address => bool) public isParticipant;

    // CAMBIO 1: Parámetro _maxTokens comentado para silenciar la advertencia de "Unused parameter"
    constructor(uint256 _tokenPriceWei, uint256 /* _maxTokens */) {
        owner = msg.sender; 
        tokenPriceWei = _tokenPriceWei; 
        token = new GovernanceToken("DAO Token", "DVT"); 
    }

    // --- Funciones Principales ---

    function openVoting() external payable {
        require(msg.sender == owner, "Solo el creador puede abrir"); 
        votingOpen = true;
        totalBudget += msg.value;
        emit VotingOpened(msg.value);
    }

    function addParticipant() external payable {
        require(!isParticipant[msg.sender], "Ya es participante");
        require(msg.value >= tokenPriceWei, "Debe comprar al menos un token"); 

        isParticipant[msg.sender] = true;
        numParticipants++;

        uint256 amount = msg.value / tokenPriceWei;
        token.mint(msg.sender, amount);

        emit ParticipantAdded(msg.sender, amount);
    }

    function addProposal(string memory _title, uint256 _budget, address _exec) external returns (uint256) {
        require(votingOpen, "La votacion no esta abierta"); 
        require(isParticipant[msg.sender], "Solo participantes"); 
        require(_exec.supportsInterface(type(IExecutableProposal).interfaceId), "Interfaz no soportada"); 

        uint256 id = nextProposalId++;
        bool signaling = (_budget == 0);

        proposals[id] = Proposal({
            title: _title,
            requiredBudget: _budget,
            executableContract: _exec,
            status: ProposalStatus.Pending,
            totalVotes: 0,
            totalTokensStaked: 0,
            creator: msg.sender,
            isSignaling: signaling
        });
        
        if (!signaling) numPendingProposals++; 
        
        emit ProposalCreated(id, _title, _budget);
        return id; 
    }

    function stake(uint256 _propId, uint256 _numVotes) external {
        require(votingOpen, "Votacion cerrada");
        Proposal storage p = proposals[_propId];
        require(p.status == ProposalStatus.Pending, "Propuesta no activa");

        uint256 votesBefore = userVotesInProposal[_propId][msg.sender];
        uint256 votesAfter = votesBefore + _numVotes;
        
        // Coste cuadrático: total = votos^2 
        uint256 costInTokens = (votesAfter**2) - (votesBefore**2); 
        
        require(token.transferFrom(msg.sender, address(this), costInTokens), "Fallo en transferencia"); 

        if (votesBefore == 0) {
            proposalVoters[_propId].push(msg.sender);
        }

        userVotesInProposal[_propId][msg.sender] = votesAfter;
        p.totalVotes += _numVotes;
        p.totalTokensStaked += costInTokens;

        emit VoteCast(_propId, msg.sender, _numVotes, costInTokens);

        if (!p.isSignaling) {
            _checkAndExecuteProposal(_propId);
        }
    }

    function _checkAndExecuteProposal(uint256 _id) internal {
        Proposal storage p = proposals[_id];
        
        // Fórmula del umbral del proyecto 
        uint256 factor = 2 + (10 * p.requiredBudget / totalBudget);
        uint256 threshold = (factor * (numParticipants + numPendingProposals)) / 10;

        if (p.totalVotes > threshold && totalBudget >= p.requiredBudget) { 
            p.status = ProposalStatus.Approved; 
            numPendingProposals--;

            // Ajuste de presupuesto dinámico 
            totalBudget += (p.totalTokensStaked * tokenPriceWei); 
            totalBudget -= p.requiredBudget; 

            token.burn(address(this), p.totalTokensStaked); 

            // CAMBIO 2: Uso del valor de retorno 'success' con 'require' para mayor seguridad 
            // Se limita el gas a 100,000 unidades
            (bool success, ) = p.executableContract.call{value: p.requiredBudget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", _id, p.totalVotes, p.totalTokensStaked)
            );
            
            require(success, "Fallo en la ejecucion externa de la propuesta"); 
            emit ProposalApproved(_id, p.requiredBudget);
        }
    }

    // --- Gestión de Tokens ---

    function buyTokens() external payable {
        require(isParticipant[msg.sender], "Inscribase primero"); 
        uint256 amount = msg.value / tokenPriceWei;
        token.mint(msg.sender, amount); 
    }

    function sellTokens(uint256 _amount) external {
        require(token.balanceOf(msg.sender) >= _amount, "Fondos insuficientes"); 
        uint256 refundAmount = _amount * tokenPriceWei;
        token.burn(msg.sender, _amount); 
        (bool success, ) = msg.sender.call{value: refundAmount}(""); 
        require(success, "Error en reembolso");
    }

    function withdrawFromProposal(uint256 _propId, uint256 _numVotes) external {
        Proposal storage p = proposals[_propId];
        require(p.status == ProposalStatus.Pending, "No pendiente"); 
        require(userVotesInProposal[_propId][msg.sender] >= _numVotes, "Votos insuficientes"); 

        uint256 votesBefore = userVotesInProposal[_propId][msg.sender];
        uint256 votesAfter = votesBefore - _numVotes;
        uint256 tokensToReturn = (votesBefore * votesBefore) - (votesAfter * votesAfter);

        userVotesInProposal[_propId][msg.sender] = votesAfter;
        p.totalVotes -= _numVotes;
        p.totalTokensStaked -= tokensToReturn;

        require(token.transfer(msg.sender, tokensToReturn), "Error transfer"); 
    }

    // --- Cierre de Votación ---

    function closeVoting() external {
        require(msg.sender == owner, "Solo owner"); 
        require(votingOpen, "Ya cerrada");

        votingOpen = false; 

        for (uint256 i = 0; i < nextProposalId; i++) {
            Proposal storage p = proposals[i];

            if (p.isSignaling) {
                // 1. Ejecutar propuestas de signaling
                (bool success, ) = p.executableContract.call{gas: 100000}(
                    abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", i, p.totalVotes, p.totalTokensStaked)
                );

                // Esta línea "usa" la variable y silencia la advertencia sin bloquear el contrato
                success; 

                // 2. Devolver tokens de signaling a sus propietarios
                _returnTokensToVoters(i);
            } else if (p.status == ProposalStatus.Pending) {
                p.status = ProposalStatus.Canceled;
                numPendingProposals--;
                _returnTokensToVoters(i); 
            }
        }

        uint256 remainingBudget = totalBudget;
        totalBudget = 0;
        if (remainingBudget > 0) {
            (bool success, ) = owner.call{value: remainingBudget}(""); 
            require(success, "Error liquidacion");
        }
    }

    function _returnTokensToVoters(uint256 _propId) internal {
        address[] storage voters = proposalVoters[_propId];
        for (uint256 j = 0; j < voters.length; j++) {
            address voter = voters[j];
            uint256 votes = userVotesInProposal[_propId][voter];
            if (votes > 0) {
                uint256 tokensToReturn = votes * votes;
                userVotesInProposal[_propId][voter] = 0;
                token.transfer(voter, tokensToReturn);
            }
        }
    }

    function getERC20() external view returns (address) {
        return address(token); 
    }
}