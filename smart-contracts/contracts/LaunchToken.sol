// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ILaunchSettings.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./IWETH.sol";

contract LaunchToken is
    ERC20Upgradeable,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable
{
    using AddressUpgradeable for address;

    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public nft;

    uint256 public nftId;

    uint256 public auctionEnd;
    uint256 public auctionLength;
    uint256 public reserveTotal;
    uint256 public livePrice;
    address payable public winning;
    enum State {
        inactive,
        live,
        ended,
        redeemed
    }
    State public auctionState;

    address public immutable launchSetting;

    address public curator;
    uint256 public fee;
    uint256 public lastClaimed;
    bool public vaultClosed;
    uint256 public votingTokens;
    mapping(address => uint256) public userPrices;

    event PriceUpdate(address indexed user, uint256 price);
    event Start(address indexed buyer, uint256 price);
    event Bid(address indexed buyer, uint256 price);

    event Won(address indexed buyer, uint256 price);
    event Redeem(address indexed redeemer);
    event Cash(address indexed owner, uint256 shares);

    event UpdateAuctionLength(uint256 length);

    event UpdateCuratorFee(uint256 fee);

    event FeeClaimed(uint256 fee);

    constructor(address _launchSetting) {
        launchSetting = _launchSetting;
    }

    function initialize(
        address _curator,
        address _nft,
        uint256 _nftId,
        uint256 _supply,
        uint256 _priceOfNft,
        uint256 _platformFee,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __ERC721Holder_init();
        __ERC1155Holder_init();
        nft = _nft;
        nftId = _nftId;
        auctionLength = 3 days;
        curator = _curator;
        fee = _platformFee;
        lastClaimed = block.timestamp;
        auctionState = State.inactive;
        userPrices[_curator] = _priceOfNft;

        _mint(_curator, _supply);
    }

    function reservePrice() public view returns (uint256) {
        return votingTokens == 0 ? 0 : reserveTotal / votingTokens;
    }

    function kickCurator(address _curator) external {
        require(msg.sender == Ownable(launchSetting).owner(), "kick:not gov");

        curator = _curator;
    }

    function removeReserve(address _user) external {
        require(msg.sender == Ownable(launchSetting).owner(), "remove:not gov");
        require(
            auctionState == State.inactive,
            "update:auction live cannot update price"
        );

        uint256 old = userPrices[_user];
        require(0 != old, "update:not an update");
        uint256 weight = balanceOf(_user);

        votingTokens -= weight;
        reserveTotal -= weight * old;

        userPrices[_user] = 0;

        emit PriceUpdate(_user, 0);
    }

    function updateCurator(address _curator) external {
        require(msg.sender == curator, "update:not curator");

        curator = _curator;
    }

    function updateAuctionLength(uint256 _length) external {
        require(msg.sender == curator, "update:not curator");
        require(
            _length >= ILaunchSettings(launchSetting).minAuctionLength() &&
                _length <= ILaunchSettings(launchSetting).maxAuctionLength(),
            "update:invalid auction length"
        );

        auctionLength = _length;
        emit UpdateAuctionLength(_length);
    }

    function updateFee(uint256 _fee) external {
        require(msg.sender == curator, "update:not curator");
        require(_fee < fee, "update:can't raise");
        require(
            _fee <= ILaunchSettings(launchSetting).maxCuratorFee(),
            "update:cannot increase fee this high"
        );

        _claimFees();

        fee = _fee;
        emit UpdateCuratorFee(fee);
    }

    function claimFees() external {
        _claimFees();
    }

    function _claimFees() internal {
        require(
            auctionState != State.ended,
            "claim:cannot claim after auction ends"
        );

        // get how much in fees the curator would make in a year
        uint256 currentAnnualFee = (fee * totalSupply()) / 1000;
        // get how much that is per second;
        uint256 feePerSecond = currentAnnualFee / 31536000;
        // get how many seconds they are eligible to claim
        uint256 sinceLastClaim = block.timestamp - lastClaimed;
        // get the amount of tokens to mint
        uint256 curatorMint = sinceLastClaim * feePerSecond;

        // now lets do the same for governance
        address govAddress = ILaunchSettings(launchSetting).feeReceiver();
        uint256 govFee = ILaunchSettings(launchSetting).governanceFee();
        currentAnnualFee = (govFee * totalSupply()) / 1000;
        feePerSecond = currentAnnualFee / 31536000;
        uint256 govMint = sinceLastClaim * feePerSecond;

        lastClaimed = block.timestamp;

        if (curator != address(0)) {
            _mint(curator, curatorMint);
            emit FeeClaimed(curatorMint);
        }
        if (govAddress != address(0)) {
            _mint(govAddress, govMint);
            emit FeeClaimed(govMint);
        }
    }

    function updateUserPrice(uint256 _new) external {
        require(
            auctionState == State.inactive,
            "update:auction live cannot update price"
        );
        uint256 old = userPrices[msg.sender];
        require(_new != old, "update:not an update");
        uint256 weight = balanceOf(msg.sender);

        if (votingTokens == 0) {
            votingTokens = weight;
            reserveTotal = weight * _new;
        }
        // they are the only one voting
        else if (weight == votingTokens && old != 0) {
            reserveTotal = weight * _new;
        }
        // previously they were not voting
        else if (old == 0) {
            uint256 averageReserve = reserveTotal / votingTokens;

            uint256 reservePriceMin = (averageReserve *
                ILaunchSettings(launchSetting).minReserveFactor()) / 1000;
            require(_new >= reservePriceMin, "update:reserve price too low");
            uint256 reservePriceMax = (averageReserve *
                ILaunchSettings(launchSetting).maxReserveFactor()) / 1000;
            require(_new <= reservePriceMax, "update:reserve price too high");

            votingTokens += weight;
            reserveTotal += weight * _new;
        }
        // they no longer want to vote
        else if (_new == 0) {
            votingTokens -= weight;
            reserveTotal -= weight * old;
        }
        // they are updating their vote
        else {
            uint256 averageReserve = (reserveTotal - (old * weight)) /
                (votingTokens - weight);

            uint256 reservePriceMin = (averageReserve *
                ILaunchSettings(launchSetting).minReserveFactor()) / 1000;
            require(_new >= reservePriceMin, "update:reserve price too low");
            uint256 reservePriceMax = (averageReserve *
                ILaunchSettings(launchSetting).maxReserveFactor()) / 1000;
            require(_new <= reservePriceMax, "update:reserve price too high");

            reserveTotal = reserveTotal + (weight * _new) - (weight * old);
        }

        userPrices[msg.sender] = _new;

        emit PriceUpdate(msg.sender, _new);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal virtual override {
        if (auctionState == State.inactive) {
            uint256 fromPrice = userPrices[_from];
            uint256 toPrice = userPrices[_to];

            // only do something if users have different reserve price
            if (toPrice != fromPrice) {
                // new holder is not a voter
                if (toPrice == 0) {
                    // get the average reserve price ignoring the senders amount
                    votingTokens -= _amount;
                    reserveTotal -= _amount * fromPrice;
                }
                // old holder is not a voter
                else if (fromPrice == 0) {
                    votingTokens += _amount;
                    reserveTotal += _amount * toPrice;
                }
                // both holders are voters
                else {
                    reserveTotal =
                        reserveTotal +
                        (_amount * toPrice) -
                        (_amount * fromPrice);
                }
            }
        }
    }

    function start() external payable {
        require(auctionState == State.inactive, "start:no auction starts");
        require(msg.value >= reservePrice(), "start:too low bid");
        require(
            votingTokens * 1000 >=
                ILaunchSettings(launchSetting).minVotePercentage() *
                    totalSupply(),
            "start:not enough voters"
        );

        auctionEnd = block.timestamp + auctionLength;
        auctionState = State.live;

        livePrice = msg.value;
        winning = payable(msg.sender);

        emit Start(msg.sender, msg.value);
    }

    function bid() external payable {
        require(auctionState == State.live, "bid:auction is not live");
        uint256 increase = ILaunchSettings(launchSetting).minBidIncrease() +
            1000;
        require(msg.value * 1000 >= livePrice * increase, "bid:too low bid");
        require(block.timestamp < auctionEnd, "bid:auction ended");

        // If bid is within 15 minutes of auction end, extend auction
        if (auctionEnd - block.timestamp <= 15 minutes) {
            auctionEnd += 15 minutes;
        }

        _sendETHOrWETH(winning, livePrice);

        livePrice = msg.value;
        winning = payable(msg.sender);

        emit Bid(msg.sender, msg.value);
    }

    function end() external {
        require(auctionState == State.live, "end:vault has already closed");
        require(block.timestamp >= auctionEnd, "end:auction live");

        _claimFees();

        // transfer erc721 to winner
        IERC721(nft).transferFrom(address(this), winning, nftId);

        auctionState = State.ended;

        emit Won(winning, livePrice);
    }

    function redeem() external {
        require(auctionState == State.inactive, "redeem:no redeeming");
        _burn(msg.sender, totalSupply());

        // transfer erc721 to redeemer
        IERC721(nft).transferFrom(address(this), msg.sender, nftId);

        auctionState = State.redeemed;

        emit Redeem(msg.sender);
    }

    function cash() external {
        require(auctionState == State.ended, "cash:vault not closed yet");
        uint256 bal = balanceOf(msg.sender);
        require(bal > 0, "cash:no tokens to cash out");
        uint256 share = (bal * address(this).balance) / totalSupply();
        _burn(msg.sender, bal);

        _sendETHOrWETH(payable(msg.sender), share);

        emit Cash(msg.sender, share);
    }

    function _sendETHOrWETH(address to, uint256 value) internal {
        // Try to transfer ETH to the given recipient.
        if (!_attemptETHTransfer(to, value)) {
            // If the transfer fails, wrap and send as WETH, so that
            // the auction is not impeded and the recipient still
            // can claim ETH via the WETH contract (similar to escrow).
            IWETH(weth).deposit{value: value}();
            IWETH(weth).transfer(to, value);
            // At this point, the recipient can unwrap WETH.
        }
    }

    function _attemptETHTransfer(address to, uint256 value)
        internal
        returns (bool)
    {
        // Here increase the gas limit a reasonable amount above the default, and try
        // to send ETH to the recipient.
        // NOTE: This might allow the recipient to attempt a limited reentrancy attack.
        (bool success, ) = to.call{value: value, gas: 30000}("");
        return success;
    }
}
