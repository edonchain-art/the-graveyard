// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721, ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Stand-in for Zombies On Base on Base Sepolia, used for live raffle test runs.
///         Token #1118 points at the real onchain Zombie 1118 metadata on Base mainnet.
contract TestZombies is ERC721Enumerable, Ownable {
    constructor() ERC721("Test Zombies On Base", "tZOB") Ownable(msg.sender) {}

    function mintBatch(address to, uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) {
            _mint(to, ids[i]);
        }
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (id == 1118) return "https://0x274ee9594512e64ba645b8f344b2d2b6e8fe140e.base.w3link.io/1118.json";
        return "";
    }
}
