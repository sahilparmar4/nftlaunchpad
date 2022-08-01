// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./LaunchInitProxy.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./LaunchToken.sol";

contract LaunchFactory is Ownable, Pausable {
    using Counters for Counters.Counter;

    Counters.Counter private _vaultTracker;

    mapping(uint256 => address) vaults;

    address public immutable launchSettings;
    address public immutable launchLogic;

    event Mint(
        address indexed token,
        uint256 id,
        uint256 priceOfToken,
        address vault,
        uint256 vaultId
    );

    constructor(address _launchSettings) {
        launchSettings = _launchSettings;
        launchLogic = address(new LaunchToken(_launchSettings));
    }

    function createVault(
        string memory _name,
        string memory _symbol,
        uint256 _supply,
        uint256 priceOfNft,
        address nft,
        uint256 nftId,
        uint256 platformFee
    ) external whenNotPaused returns (uint256) {
        bytes memory _initializeData = abi.encodeWithSignature(
            "initialize(address,address,uint256,uint256,uint256,uint256,string,string)",
            msg.sender,
            nft,
            nftId,
            _supply,
            priceOfNft,
            platformFee,
            _name,
            _symbol
        );

        address newVault = address(
            new LaunchInitProxy(launchLogic, _initializeData)
        );

        emit Mint(nft, nftId, priceOfNft, newVault, _vaultTracker.current());

        IERC721(nft).safeTransferFrom(msg.sender, newVault, nftId);

        vaults[_vaultTracker.current()] = newVault;

        _vaultTracker.increment();

        return _vaultTracker.current() - 1;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
