// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GovernanceToken is ERC20 {
    address public immutable votingContract;
    uint256 public immutable maxSupply;

    modifier onlyVoting() {
        require(msg.sender == votingContract, "Only voting contract");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply
    ) ERC20(name, symbol) {
        require(_maxSupply > 0, "Max supply must be > 0");
        votingContract = msg.sender;
        maxSupply = _maxSupply;
    }

    function mint(address to, uint256 amount) external onlyVoting {
        require(totalSupply() + amount <= maxSupply, "Max token supply exceeded");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVoting {
        _burn(from, amount);
    }
}
