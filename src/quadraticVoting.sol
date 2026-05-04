// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./governanceToken.sol";
import "./IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

// Contrato principal que gestiona participantes, propuestas, votos y presupuesto.
contract QuadraticVoting {
    using ERC165Checker for address;

    // Eventos para trazabilidad de las acciones principales.
    event VotingOpened(uint256 indexed roundId, uint256 initialBudget);
    event VotingClosed(uint256 indexed roundId, uint256 refundedBudget);
    event SignalingExecutionFailed(uint256 indexed proposalId);
    event SignalingExecuted(uint256 indexed proposalId, bool success);
    event RefundClaimed(uint256 indexed proposalId, address indexed voter, uint256 tokensReturned);
    event ParticipantAdded(address indexed participant, uint256 tokensBought);
    event ParticipantRemoved(address indexed participant);
    event ProposalCreated(uint256 indexed id, string title, uint256 budget, bool isSignaling);
    event ProposalCanceled(uint256 indexed id);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint256 votesAdded, uint256 tokenCost);
    event VotesWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 votesRemoved, uint256 tokensReturned);
    event ProposalApproved(uint256 indexed id, uint256 fundsSent, uint256 threshold);
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 costWei);
    event TokensSold(address indexed seller, uint256 amount, uint256 refundWei);

    // Datos básicos del sistema de votación.
    address public immutable owner;
    GovernanceToken public immutable token;
    uint256 public immutable tokenPriceWei;
    uint256 public totalBudget;
    bool public votingOpen;

    // Variables de control de rondas, propuestas y seguridad.
    uint256 public currentRound;
    uint256 public numParticipants;
    uint256 public numPendingProposals;
    uint256 private nextProposalId;
    uint256[] private currentProposalIds;
    bool private locked;

    // Registro de participantes y rondas cerradas.
    mapping(address => bool) public isParticipant;
    mapping(uint256 => bool) public roundClosed;

    // Estados posibles de una propuesta.
    enum ProposalStatus {
        Pending,
        Approved,
        Canceled
    }

    // Información almacenada para cada propuesta.
    struct Proposal {
        string title;
        string description;
        uint256 requiredBudget;
        address executableContract;
        ProposalStatus status;
        uint256 totalVotes;
        uint256 totalTokensStaked;
        address creator;
        bool isSignaling;
        bool exists;
        uint256 roundId;
    }

    // Almacén de propuestas y votos por usuario.
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public userVotesInProposal;

    // Restringe funciones al propietario del contrato.
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // Restringe funciones a participantes registrados.
    modifier onlyParticipant() {
        require(isParticipant[msg.sender], "Only participant");
        _;
    }

    // Exige que haya una votación abierta.
    modifier whenVotingOpen() {
        require(votingOpen, "Voting is closed");
        _;
    }

    // Evita reentradas en funciones sensibles.
    modifier nonReentrant() {
        require(!locked, "Reentrancy blocked");
        locked = true;
        _;
        locked = false;
    }

    // Inicializa el precio del token, el máximo de tokens y crea el ERC20.
    constructor(uint256 _tokenPriceWei, uint256 _maxTokens) {
        require(_tokenPriceWei > 0, "Token price must be > 0");
        require(_maxTokens > 0, "Max tokens must be > 0");
        owner = msg.sender;
        tokenPriceWei = _tokenPriceWei;
        token = new GovernanceToken("DAO Token", "DVT", _maxTokens);
    }

    // Evita recibir Ether fuera de funciones controladas.
    receive() external payable {
        revert("Direct Ether not accepted");
    }

    // Abre una nueva ronda de votación con presupuesto inicial.
    function openVoting() external payable onlyOwner {
        require(!votingOpen, "Voting already open");
        require(msg.value > 0, "Initial budget required");

        currentRound += 1;
        votingOpen = true;
        totalBudget = msg.value;
        numPendingProposals = 0;
        delete currentProposalIds;

        emit VotingOpened(currentRound, msg.value);
    }

    // Registra participantes y acuña tokens según el Ether enviado.
    function addParticipant() external payable nonReentrant {
        uint256 tokensToMint = msg.value / tokenPriceWei;
        require(tokensToMint > 0, "Must buy at least 1 token");

        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            numParticipants += 1;
        }

        token.mint(msg.sender, tokensToMint);
        _refundRemainder(msg.sender, msg.value - (tokensToMint * tokenPriceWei));

        emit ParticipantAdded(msg.sender, tokensToMint);
    }

    // Permite darse de baja como participante.
    function removeParticipant() external onlyParticipant nonReentrant {
        isParticipant[msg.sender] = false;
        numParticipants -= 1;
        emit ParticipantRemoved(msg.sender);
    }

    // Crea una propuesta y verifica que el contrato externo soporte la interfaz requerida.
    function addProposal(
        string memory _title,
        string memory _description,
        uint256 _budget,
        address _exec
    ) external whenVotingOpen onlyParticipant nonReentrant returns (uint256) {
        require(bytes(_title).length > 0, "Empty title");
        require(_exec != address(0), "Invalid proposal contract");
        require(_exec.supportsInterface(type(IExecutableProposal).interfaceId), "Contract must implement IExecutableProposal");

        uint256 proposalId = nextProposalId;
        nextProposalId += 1;
        bool signaling = _budget == 0;

        proposals[proposalId] = Proposal({
            title: _title,
            description: _description,
            requiredBudget: _budget,
            executableContract: _exec,
            status: ProposalStatus.Pending,
            totalVotes: 0,
            totalTokensStaked: 0,
            creator: msg.sender,
            isSignaling: signaling,
            exists: true,
            roundId: currentRound
        });

        currentProposalIds.push(proposalId);

        if (!signaling) {
            numPendingProposals += 1;
        }

        emit ProposalCreated(proposalId, _title, _budget, signaling);
        return proposalId;
    }

    // Cancela una propuesta pendiente sin recorrer votantes.
    function cancelProposal(uint256 proposalId) external whenVotingOpen nonReentrant {
        Proposal storage proposal = _getExistingProposal(proposalId);
        _requireCurrentRoundProposal(proposal);
        require(msg.sender == proposal.creator, "Only proposal creator");
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");

        proposal.status = ProposalStatus.Canceled;
        if (!proposal.isSignaling) {
            numPendingProposals -= 1;
        }

        emit ProposalCanceled(proposalId);
    }

    // Compra tokens adicionales para un participante.
    function buyTokens() external payable onlyParticipant nonReentrant {
        uint256 tokensToMint = msg.value / tokenPriceWei;
        require(tokensToMint > 0, "Must buy at least 1 token");

        token.mint(msg.sender, tokensToMint);
        uint256 spentWei = tokensToMint * tokenPriceWei;
        _refundRemainder(msg.sender, msg.value - spentWei);

        emit TokensPurchased(msg.sender, tokensToMint, spentWei);
    }

    // Vende tokens libres y devuelve su equivalente en Ether.
    function sellTokens(uint256 amount) external onlyParticipant nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(token.balanceOf(msg.sender) >= amount, "Insufficient token balance");

        uint256 refundAmount = amount * tokenPriceWei;
        require(address(this).balance >= refundAmount, "Insufficient Ether in contract");

        token.burn(msg.sender, amount);
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Ether transfer failed");

        emit TokensSold(msg.sender, amount, refundAmount);
    }

    // Devuelve la dirección del token ERC20 usado por el sistema.
    function getERC20() external view returns (address) {
        return address(token);
    }

    // Consulta propuestas de financiación pendientes de la ronda actual.
    function getPendingProposals() external view whenVotingOpen returns (uint256[] memory) {
        return _getProposalsByFilter(ProposalStatus.Pending, false);
    }

    // Consulta propuestas de financiación aprobadas de la ronda actual.
    function getApprovedProposals() external view whenVotingOpen returns (uint256[] memory) {
        return _getProposalsByFilter(ProposalStatus.Approved, false);
    }

    // Consulta propuestas de signaling pendientes de la ronda actual.
    function getSignalingProposals() external view whenVotingOpen returns (uint256[] memory) {
        return _getProposalsByFilter(ProposalStatus.Pending, true);
    }

    // Devuelve la información principal de una propuesta.
    function getProposalInfo(uint256 proposalId)
        external
        view
        whenVotingOpen
        returns (
            string memory title,
            string memory description,
            uint256 budget,
            address executable,
            ProposalStatus status,
            uint256 totalVotes,
            uint256 totalTokensStaked,
            address creator,
            bool isSignaling
        )
    {
        Proposal storage proposal = _getExistingProposal(proposalId);
        return (
            proposal.title,
            proposal.description,
            proposal.requiredBudget,
            proposal.executableContract,
            proposal.status,
            proposal.totalVotes,
            proposal.totalTokensStaked,
            proposal.creator,
            proposal.isSignaling
        );
    }

    // Deposita votos aplicando coste cuadrático acumulado.
    function stake(uint256 proposalId, uint256 votesToAdd) external whenVotingOpen onlyParticipant nonReentrant {
        require(votesToAdd > 0, "Votes must be > 0");
        Proposal storage proposal = _getExistingProposal(proposalId);
        _requireCurrentRoundProposal(proposal);
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");

        uint256 previousVotes = userVotesInProposal[proposalId][msg.sender];
        uint256 updatedVotes = previousVotes + votesToAdd;
        uint256 tokenCost = (updatedVotes * updatedVotes) - (previousVotes * previousVotes);

        require(token.transferFrom(msg.sender, address(this), tokenCost), "Token transferFrom failed");

        userVotesInProposal[proposalId][msg.sender] = updatedVotes;
        proposal.totalVotes += votesToAdd;
        proposal.totalTokensStaked += tokenCost;

        emit VoteCast(proposalId, msg.sender, votesToAdd, tokenCost);

        if (!proposal.isSignaling) {
            _checkAndExecuteProposal(proposalId);
        }
    }

    // Retira votos de una propuesta pendiente y devuelve los tokens correspondientes.
    function withdrawFromProposal(uint256 proposalId, uint256 votesToRemove)
        external
        whenVotingOpen
        nonReentrant
    {
        require(votesToRemove > 0, "Votes must be > 0");
        Proposal storage proposal = _getExistingProposal(proposalId);
        _requireCurrentRoundProposal(proposal);
        require(proposal.status == ProposalStatus.Pending, "Proposal already finalized");

        uint256 previousVotes = userVotesInProposal[proposalId][msg.sender];
        require(previousVotes >= votesToRemove, "Not enough votes staked");

        uint256 updatedVotes = previousVotes - votesToRemove;
        uint256 tokensToReturn = (previousVotes * previousVotes) - (updatedVotes * updatedVotes);

        userVotesInProposal[proposalId][msg.sender] = updatedVotes;
        proposal.totalVotes -= votesToRemove;
        proposal.totalTokensStaked -= tokensToReturn;

        require(token.transfer(msg.sender, tokensToReturn), "Token refund failed");
        emit VotesWithdrawn(proposalId, msg.sender, votesToRemove, tokensToReturn);
    }

    // Cierra la ronda sin ejecutar signaling ni devolver tokens en bucle.
    function closeVoting() external onlyOwner whenVotingOpen nonReentrant {
        uint256 closedRound = currentRound;
        votingOpen = false;
        roundClosed[closedRound] = true;
        delete currentProposalIds;
        numPendingProposals = 0;

        uint256 remainingBudget = totalBudget;
        totalBudget = 0;
        if (remainingBudget > 0) {
            (bool success, ) = owner.call{value: remainingBudget}("");
            require(success, "Owner refund failed");
        }

        emit VotingClosed(closedRound, remainingBudget);
    }

    // Permite reclamar tokens bloqueados en propuestas canceladas o no aprobadas.
    function claimRefundFromProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = _getExistingProposal(proposalId);
        require(_canClaimRefund(proposal), "Refund not available");

        /*
        * Si es una propuesta de signaling de una ronda cerrada pero sigue Pending,
        * primero debe ejecutarse con executeSignalingProposal.
        *
        * Esto evita que un usuario reclame antes y reduzca totalVotes /
        * totalTokensStaked antes de que esos valores se envien al contrato externo.
        */
        require(
            !(proposal.isSignaling && proposal.status == ProposalStatus.Pending && roundClosed[proposal.roundId]),
            "Execute signaling first"
        );

        uint256 votes = userVotesInProposal[proposalId][msg.sender];
        require(votes > 0, "No tokens to claim");

        uint256 tokensToReturn = votes * votes;

        require(proposal.totalVotes >= votes, "Invalid vote accounting");
        require(proposal.totalTokensStaked >= tokensToReturn, "Invalid token accounting");

        userVotesInProposal[proposalId][msg.sender] = 0;
        proposal.totalVotes -= votes;
        proposal.totalTokensStaked -= tokensToReturn;

        require(token.transfer(msg.sender, tokensToReturn), "Token return failed");

        emit RefundClaimed(proposalId, msg.sender, tokensToReturn);
    }

    // Ejecuta una propuesta de signaling bajo demanda tras cerrar su ronda.
    function executeSignalingProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = _getExistingProposal(proposalId);
        require(proposal.isSignaling, "Not signaling");
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");
        require(roundClosed[proposal.roundId], "Voting round not closed");

        proposal.status = ProposalStatus.Canceled;

        (bool success, ) = proposal.executableContract.call{gas: 100000}(
            abi.encodeWithSelector(
                IExecutableProposal.executeProposal.selector,
                proposalId,
                proposal.totalVotes,
                proposal.totalTokensStaked
            )
        );

        if (!success) {
            emit SignalingExecutionFailed(proposalId);
        }
        emit SignalingExecuted(proposalId, success);
    }

    // Consulta cuántos tokens puede reclamar un votante.
    function getClaimableTokens(uint256 proposalId, address voter) external view returns (uint256) {
        Proposal storage proposal = _getExistingProposal(proposalId);
        if (!_canClaimRefund(proposal)) {
            return 0;
        }

        uint256 votes = userVotesInProposal[proposalId][voter];
        return votes * votes;
    }

    // Comprueba si una propuesta de financiación supera el umbral y la ejecuta.
    function _checkAndExecuteProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.status != ProposalStatus.Pending || proposal.isSignaling) {
            return;
        }
        if (totalBudget < proposal.requiredBudget || totalBudget == 0) {
            return;
        }

        uint256 threshold = _calculateThreshold(proposal.requiredBudget);
        if (proposal.totalVotes <= threshold) {
            return;
        }

        proposal.status = ProposalStatus.Approved;
        numPendingProposals -= 1;

        uint256 stakedEtherEquivalent = proposal.totalTokensStaked * tokenPriceWei;
        totalBudget = totalBudget + stakedEtherEquivalent - proposal.requiredBudget;
        token.burn(address(this), proposal.totalTokensStaked);

        (bool success, ) = proposal.executableContract.call{value: proposal.requiredBudget, gas: 100000}(
            abi.encodeWithSelector(
                IExecutableProposal.executeProposal.selector,
                proposalId,
                proposal.totalVotes,
                proposal.totalTokensStaked
            )
        );
        require(success, "Proposal execution failed");

        emit ProposalApproved(proposalId, proposal.requiredBudget, threshold);
    }

    // Calcula el umbral usando escala entera para representar 0.2.
    function _calculateThreshold(uint256 proposalBudget) internal view returns (uint256) {
        if (totalBudget == 0) {
            return type(uint256).max;
        }

        uint256 scaledThreshold =
            (2 * numParticipants) +
            ((10 * proposalBudget * numParticipants) / totalBudget) +
            (10 * numPendingProposals);

        return scaledThreshold / 10;
    }

    // Recupera una propuesta existente o revierte.
    function _getExistingProposal(uint256 proposalId) internal view returns (Proposal storage proposal) {
        proposal = proposals[proposalId];
        require(proposal.exists, "Proposal does not exist");
    }

    // Filtra propuestas de la ronda actual por estado y tipo.
    function _getProposalsByFilter(ProposalStatus statusFilter, bool onlySignaling)
        internal
        view
        returns (uint256[] memory)
    {
        uint256 count = 0;

        for (uint256 j = 0; j < currentProposalIds.length; j++) {
            uint256 id = currentProposalIds[j];
            Proposal storage proposal = proposals[id];

            if (
                proposal.exists &&
                proposal.status == statusFilter &&
                proposal.isSignaling == onlySignaling &&
                proposal.roundId == currentRound
            ) {
                count += 1;
            }
        }

        uint256[] memory ids = new uint256[](count);
        uint256 idx = 0;

        for (uint256 j = 0; j < currentProposalIds.length; j++) {
            uint256 id = currentProposalIds[j];
            Proposal storage proposal = proposals[id];

            if (
                proposal.exists &&
                proposal.status == statusFilter &&
                proposal.isSignaling == onlySignaling &&
                proposal.roundId == currentRound
            ) {
                ids[idx] = id;
                idx += 1;
            }
        }

        return ids;
    }

    // Determina si los tokens bloqueados en una propuesta son reclamables.
    function _canClaimRefund(Proposal storage proposal) internal view returns (bool) {
        if (proposal.status == ProposalStatus.Approved) {
            return false;
        }

        if (proposal.status == ProposalStatus.Canceled) {
            return true;
        }

        // Si es signaling y sigue Pending, primero debe procesarse
        // con executeSignalingProposal.
        if (proposal.isSignaling) {
            return false;
        }

        // Propuesta de financiación no aprobada de una ronda cerrada.
        return roundClosed[proposal.roundId];
    }

    // Evita operar sobre propuestas de rondas anteriores durante una votación activa.
    function _requireCurrentRoundProposal(Proposal storage proposal) internal view {
        require(proposal.roundId == currentRound, "Proposal is not from current round");
    }

    // Devuelve Ether sobrante cuando el pago no es múltiplo del precio del token.
    function _refundRemainder(address recipient, uint256 remainder) internal {
        if (remainder == 0) {
            return;
        }
        (bool success, ) = recipient.call{value: remainder}("");
        require(success, "Remainder refund failed");
    }
}