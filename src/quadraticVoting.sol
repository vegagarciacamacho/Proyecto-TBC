// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./governanceToken.sol";
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

    // --- Estado ---
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
        string description; // Añadido según punto 2.2
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

    constructor(uint256 _tokenPriceWei, uint256 /* _maxTokens */) {
        owner = msg.sender;
        tokenPriceWei = _tokenPriceWei;
        token = new GovernanceToken("DAO Token", "DVT");
    }

    // --- Punto 2.2: Funciones Obligatorias ---

    function openVoting() external payable {
        require(msg.sender == owner, "Solo creador");
        votingOpen = true;
        totalBudget += msg.value;
        emit VotingOpened(msg.value);
    }

    function addParticipant() external payable {
        require(msg.value >= tokenPriceWei, "Minimo 1 token");
        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            numParticipants++;
        }
        uint256 amount = msg.value / tokenPriceWei;
        token.mint(msg.sender, amount);
        emit ParticipantAdded(msg.sender, amount);
    }

    // Nueva: removeParticipant (Punto 2.2)
    function removeParticipant() external {
        require(isParticipant[msg.sender], "No es participante");
        isParticipant[msg.sender] = false;
        numParticipants--;
    }

    function addProposal(
        string memory _title, 
        string memory _desc, 
        uint256 _budget, 
        address _exec
    ) external returns (uint256) {
        require(votingOpen, "Cerrada");
        require(isParticipant[msg.sender], "Solo participantes");
        require(_exec.supportsInterface(type(IExecutableProposal).interfaceId), "ERC165 fallido");

        uint256 id = nextProposalId++;
        bool signaling = (_budget == 0);

        proposals[id] = Proposal({
            title: _title,
            description: _desc,
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

    // Nueva: cancelProposal (Punto 2.2)
    function cancelProposal(uint256 _id) external {
        require(votingOpen, "Cerrada");
        Proposal storage p = proposals[_id];
        require(msg.sender == p.creator, "Solo el autor");
        require(p.status == ProposalStatus.Pending, "Ya finalizada");

        p.status = ProposalStatus.Canceled;
        if (!p.isSignaling) numPendingProposals--;
        _returnTokensToVoters(_id);
    }

    function stake(uint256 _propId, uint256 _numVotes) external {
        require(votingOpen && isParticipant[msg.sender], "No puede votar");
        Proposal storage p = proposals[_propId];
        require(p.status == ProposalStatus.Pending, "No activa");

        uint256 votesBefore = userVotesInProposal[_propId][msg.sender];
        uint256 votesAfter = votesBefore + _numVotes;
        uint256 cost = (votesAfter**2) - (votesBefore**2); // Coste cuadratico
        
        require(token.transferFrom(msg.sender, address(this), cost), "Falta approve");

        if (votesBefore == 0) proposalVoters[_propId].push(msg.sender);

        userVotesInProposal[_propId][msg.sender] = votesAfter;
        p.totalVotes += _numVotes;
        p.totalTokensStaked += cost;

        emit VoteCast(_propId, msg.sender, _numVotes, cost);
        if (!p.isSignaling) _checkAndExecuteProposal(_propId);
    }

    function _checkAndExecuteProposal(uint256 _id) internal {
        Proposal storage p = proposals[_id];
        uint256 factor = 2 + (10 * p.requiredBudget / totalBudget);
        uint256 threshold = (factor * (numParticipants + numPendingProposals)) / 10;

        if (p.totalVotes > threshold && totalBudget >= p.requiredBudget) {
            p.status = ProposalStatus.Approved;
            numPendingProposals--;
            totalBudget += (p.totalTokensStaked * tokenPriceWei); // Aumenta presupuesto
            totalBudget -= p.requiredBudget; // Disminuye presupuesto
            token.burn(address(this), p.totalTokensStaked); // Elimina tokens consumidos

            (bool success, ) = p.executableContract.call{value: p.requiredBudget, gas: 100000}(
                abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", _id, p.totalVotes, p.totalTokensStaked)
            );
            require(success, "Ejecucion fallo");
            emit ProposalApproved(_id, p.requiredBudget);
        }
    }

    // --- Punto 2.2: Getters Obligatorios ---

    function getPendingProposals() external view returns (uint256[] memory) {
        return _getProposalsByStatus(ProposalStatus.Pending, false);
    }

    function getApprovedProposals() external view returns (uint256[] memory) {
        return _getProposalsByStatus(ProposalStatus.Approved, false);
    }

    // Devuelve IDs de TODAS las propuestas de signaling (presupuesto 0) 
    function getSignalingProposals() external view returns (uint256[] memory) {
        require(votingOpen, "Votacion cerrada"); // [cite: 108]
        uint256 count = 0;
        for (uint256 i = 0; i < nextProposalId; i++) {
            if (proposals[i].isSignaling) count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < nextProposalId; i++) {
            if (proposals[i].isSignaling) ids[idx++] = i;
        }
        return ids;
    }

    // Devuelve los datos asociados a una propuesta por su ID 
    function getProposalInfo(uint256 _id) external view returns (
        string memory title,
        string memory description,
        uint256 budget,
        address executable,
        ProposalStatus status,
        uint256 votes
    ) {
        require(votingOpen, "Votacion cerrada"); // [cite: 110]
        Proposal storage p = proposals[_id];
        return (p.title, p.description, p.requiredBudget, p.executableContract, p.status, p.totalVotes);
    }

    function _getProposalsByStatus(ProposalStatus _status, bool _onlySignaling) internal view returns (uint256[] memory) {
        uint256 count = 0;
        for(uint256 i=0; i<nextProposalId; i++) {
            if (proposals[i].status == _status && proposals[i].isSignaling == _onlySignaling) count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        for(uint256 i=0; i<nextProposalId; i++) {
            if (proposals[i].status == _status && proposals[i].isSignaling == _onlySignaling) result[idx++] = i;
        }
        return result;
    }

    // --- Punto 2.2: Cierre y Gestión ---

    function closeVoting() external {
        require(msg.sender == owner && votingOpen, "Solo owner");
        votingOpen = false;

        for (uint256 i = 0; i < nextProposalId; i++) {
            Proposal storage p = proposals[i];
            if (p.isSignaling) {
                (bool success, ) = p.executableContract.call{gas: 100000}(
                    abi.encodeWithSignature("executeProposal(uint256,uint256,uint256)", i, p.totalVotes, p.totalTokensStaked)
                );
                success; // Silencia warning de unused variable
                _returnTokensToVoters(i);
            } else if (p.status == ProposalStatus.Pending) {
                p.status = ProposalStatus.Canceled;
                numPendingProposals--;
                _returnTokensToVoters(i);
            }
        }

        uint256 remaining = totalBudget;
        totalBudget = 0;
        if (remaining > 0) {
            (bool success, ) = owner.call{value: remaining}("");
            require(success, "Error liquidacion");
        }
    }

    function _returnTokensToVoters(uint256 _id) internal {
        address[] storage voters = proposalVoters[_id];
        for (uint256 j = 0; j < voters.length; j++) {
            address voter = voters[j];
            uint256 votes = userVotesInProposal[_id][voter];
            if (votes > 0) {
                uint256 tokensToReturn = votes * votes;
                userVotesInProposal[_id][voter] = 0;

                token.transfer(voter, tokensToReturn); 
            }
        }
    }

    function buyTokens() external payable {
        require(isParticipant[msg.sender], "Inscribase");
        token.mint(msg.sender, msg.value / tokenPriceWei);
    }

    function sellTokens(uint256 _amount) external {
        require(token.balanceOf(msg.sender) >= _amount, "Fondos insuficientes");
        uint256 refundAmount = _amount * tokenPriceWei;
        
        token.burn(msg.sender, _amount);
        
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Error en reembolso");
    }

    function getERC20() external view returns (address) { return address(token); }

}