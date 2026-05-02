// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./governanceToken.sol";
import "./IExecutableProposal.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

contract QuadraticVoting {
    using ERC165Checker for address;

    event VotingOpened(uint256 initialBudget);
    event VotingClosed(uint256 refundedBudget);
    event SignalingExecutionFailed(uint256 indexed proposalId);
    event ParticipantAdded(address indexed participant, uint256 tokensBought);
    event ParticipantRemoved(address indexed participant);
    event ProposalCreated(uint256 indexed id, string title, uint256 budget, bool isSignaling);
    event ProposalCanceled(uint256 indexed id);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint256 votesAdded, uint256 tokenCost);
    event VotesWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 votesRemoved, uint256 tokensReturned);
    event ProposalApproved(uint256 indexed id, uint256 fundsSent, uint256 threshold);
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 costWei);
    event TokensSold(address indexed seller, uint256 amount, uint256 refundWei);

    address public immutable owner;
    GovernanceToken public immutable token;
    uint256 public immutable tokenPriceWei;
    uint256 public totalBudget;
    bool public votingOpen;

    uint256 public numParticipants;
    uint256 public numPendingProposals;
    uint256 private nextProposalId;
    uint256[] private currentProposalIds;
    bool private locked;

    mapping(address => bool) public isParticipant;

    enum ProposalStatus {
        Pending,
        Approved,
        Canceled
    }

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
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public userVotesInProposal;
    mapping(uint256 => address[]) private proposalVoters;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyParticipant() {
        require(isParticipant[msg.sender], "Only participant");
        _;
    }

    modifier whenVotingOpen() {
        require(votingOpen, "Voting is closed");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Reentrancy blocked");
        locked = true;
        _;
        locked = false;
    }

    constructor(uint256 _tokenPriceWei, uint256 _maxTokens) {
        require(_tokenPriceWei > 0, "Token price must be > 0");
        require(_maxTokens > 0, "Max tokens must be > 0");
        owner = msg.sender;
        tokenPriceWei = _tokenPriceWei;
        token = new GovernanceToken("DAO Token", "DVT", _maxTokens);
    }

    receive() external payable {
    revert("Direct Ether not accepted");
    }

    function openVoting() external payable onlyOwner {
        require(!votingOpen, "Voting already open");
        require(msg.value > 0, "Initial budget required");
        votingOpen = true;
        totalBudget = msg.value;
        emit VotingOpened(msg.value);
    }

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

    function removeParticipant() external onlyParticipant nonReentrant {
        isParticipant[msg.sender] = false;
        numParticipants -= 1;
        emit ParticipantRemoved(msg.sender);
    }

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
            exists: true
        });
        
        currentProposalIds.push(proposalId);

        if (!signaling) {
            numPendingProposals += 1;
        }

        emit ProposalCreated(proposalId, _title, _budget, signaling);
        return proposalId;
    }

    function cancelProposal(uint256 proposalId) external whenVotingOpen nonReentrant {
        Proposal storage proposal = _getExistingProposal(proposalId);
        require(msg.sender == proposal.creator, "Only proposal creator");
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");

        proposal.status = ProposalStatus.Canceled;
        if (!proposal.isSignaling) {
            numPendingProposals -= 1;
        }
        _returnTokensToVoters(proposalId);

        emit ProposalCanceled(proposalId);
    }

    function buyTokens() external payable onlyParticipant nonReentrant {
        uint256 tokensToMint = msg.value / tokenPriceWei;
        require(tokensToMint > 0, "Must buy at least 1 token");

        token.mint(msg.sender, tokensToMint);
        uint256 spentWei = tokensToMint * tokenPriceWei;
        _refundRemainder(msg.sender, msg.value - spentWei);

        emit TokensPurchased(msg.sender, tokensToMint, spentWei);
    }

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

    function getERC20() external view returns (address) {
        return address(token);
    }

    function getPendingProposals() external view whenVotingOpen returns (uint256[] memory) {
        return _getProposalsByFilter(ProposalStatus.Pending, false);
    }

    function getApprovedProposals() external view whenVotingOpen returns (uint256[] memory) {
        return _getProposalsByFilter(ProposalStatus.Approved, false);
    }

    function getSignalingProposals() external view whenVotingOpen returns (uint256[] memory) {
        uint256 count = 0;

        for (uint256 j = 0; j < currentProposalIds.length; j++) {
            uint256 id = currentProposalIds[j];
            Proposal storage proposal = proposals[id];

            if (
                proposal.exists &&
                proposal.isSignaling &&
                proposal.status == ProposalStatus.Pending
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
                proposal.isSignaling &&
                proposal.status == ProposalStatus.Pending
            ) {
                ids[idx] = id;
                idx += 1;
            }
        }

        return ids;
    }

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

    function stake(uint256 proposalId, uint256 votesToAdd) external whenVotingOpen onlyParticipant nonReentrant {
        require(votesToAdd > 0, "Votes must be > 0");
        Proposal storage proposal = _getExistingProposal(proposalId);
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");

        uint256 previousVotes = userVotesInProposal[proposalId][msg.sender];
        uint256 updatedVotes = previousVotes + votesToAdd;
        uint256 tokenCost = (updatedVotes * updatedVotes) - (previousVotes * previousVotes);

        require(token.transferFrom(msg.sender, address(this), tokenCost), "Token transferFrom failed");

        if (previousVotes == 0) {
            proposalVoters[proposalId].push(msg.sender);
        }

        userVotesInProposal[proposalId][msg.sender] = updatedVotes;
        proposal.totalVotes += votesToAdd;
        proposal.totalTokensStaked += tokenCost;

        emit VoteCast(proposalId, msg.sender, votesToAdd, tokenCost);

        if (!proposal.isSignaling) {
            _checkAndExecuteProposal(proposalId);
        }
    }

    function withdrawFromProposal(uint256 proposalId, uint256 votesToRemove)
        external
        whenVotingOpen
        nonReentrant
    {
        require(votesToRemove > 0, "Votes must be > 0");
        Proposal storage proposal = _getExistingProposal(proposalId);
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

    function closeVoting() external onlyOwner whenVotingOpen nonReentrant {
        votingOpen = false;

        for (uint256 j = 0; j < currentProposalIds.length; j++) {
            uint256 i = currentProposalIds[j];
            Proposal storage proposal = proposals[i];
            if (!proposal.exists) {
                continue;
            }

            if (proposal.isSignaling && proposal.status == ProposalStatus.Pending) {

                (bool success, ) = proposal.executableContract.call{gas: 100000}(
                    abi.encodeWithSelector(
                        IExecutableProposal.executeProposal.selector,
                        i,
                        proposal.totalVotes,
                        proposal.totalTokensStaked
                    )
                );

                if (!success) {
                    emit SignalingExecutionFailed(i);
                }

                _returnTokensToVoters(i);
                proposal.status = ProposalStatus.Canceled;

            } else if (proposal.status == ProposalStatus.Pending) {
                proposal.status = ProposalStatus.Canceled;
                numPendingProposals -= 1;
                _returnTokensToVoters(i);
            }

            delete proposalVoters[i];
            delete proposals[i];
        }

        delete currentProposalIds;
        numPendingProposals = 0;

        uint256 remainingBudget = totalBudget;
        totalBudget = 0;
        if (remainingBudget > 0) {
            (bool success, ) = owner.call{value: remainingBudget}("");
            require(success, "Owner refund failed");
        }

        emit VotingClosed(remainingBudget);
    }

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

    function _returnTokensToVoters(uint256 proposalId) internal {
        address[] storage voters = proposalVoters[proposalId];
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            uint256 votes = userVotesInProposal[proposalId][voter];
            if (votes == 0) {
                continue;
            }

            uint256 tokensToReturn = votes * votes;
            userVotesInProposal[proposalId][voter] = 0;
            require(token.transfer(voter, tokensToReturn), "Token return failed");
        }
    }

    function _getExistingProposal(uint256 proposalId) internal view returns (Proposal storage proposal) {
        proposal = proposals[proposalId];
        require(proposal.exists, "Proposal does not exist");
    }

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
                proposal.isSignaling == onlySignaling
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
                proposal.isSignaling == onlySignaling
            ) {
                ids[idx] = id;
                idx += 1;
            }
        }

        return ids;
    }

    function _refundRemainder(address recipient, uint256 remainder) internal {
        if (remainder == 0) {
            return;
        }
        (bool success, ) = recipient.call{value: remainder}("");
        require(success, "Remainder refund failed");
    }
}
