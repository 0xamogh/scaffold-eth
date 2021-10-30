// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import './ERC721Pausable.sol';

import '@chainlink/contracts/src/v0.8/VRFConsumerBase.sol';

contract AccessPass is ERC721, ERC721Enumerable, Ownable, ERC721Pausable, VRFConsumerBase {
  bytes32 internal keyHash;
  uint256 internal fee;
  uint256 public randomResult;

  using SafeMath for uint256;
  using Counters for Counters.Counter;

  Counters.Counter private _tokenIdTracker;

  // Defines the different stages of the game
  enum GameState {
    PREMINT, // Before the game, when minting is not available yet.
    MINTING, // Before the game, when minting is available to the public.
    STARTED, // During one of the rounds of the game.
    FINISHED // After the game, when there is a winner.
  }

  // Global vars
  bool private _isAdminBurnEnabled = false; // Flag to indicate whether the admin should be able to burn the supply
  bool private creatorHasClaimed = false; // Flag to indicate whether the creator has claimed reward
  uint256 public currentRound = 0; // Tracks the current round
  uint256 public currentBurn = 0; // Tracks the number of burns that have been requested so far
  string public baseTokenURI; // Base token URI
  address public winnerAddress; // The address of the winner of the game
  GameState public gameState; // The current state of the game
  uint256 public roundTime = 1 hours;
  uint256 public roundStartedAt = 0;
  // Constants
  uint256 public constant NUM_ROUNDS = 7; // Number of rounds this game will last
  uint256 public constant MAX_ELEMENTS = 2**NUM_ROUNDS; // Max number of tokens minted
  uint256 public constant PRICE = 1 * 10**20; // Price to mint a single token, 100 MATIC
  uint256 public constant MAX_BY_MINT = 5; // Max number of tokens to be minted in a single transaction
  uint256 public constant CREATOR_PERCENTAGE = 20; // Percentage given to creators

  constructor(string memory baseURI, string burningBallURI)
    ERC721('Squid Arena', 'SQUID')
    VRFConsumerBase(
      0x8C7382F9D8f56b33781fE506E897a4F1e2d17255, // VRF Coordinator (Mumbai)
      0x326C977E6efc84E512bB9C30f76E30c160eD06FB // LINK Contract Token (Mumbai)
    )
  {
    keyHash = 0x6e75b569a01ef56d18cab6a8e71e6600d6ce853834d4a5748b720d06f878b3a4;
    fee = 1 * 10**14; // 0.0001 LINK (Varies by network)
    setBaseURI(baseURI);
    pause(true);
    gameState = GameState.PREMINT;
  }

  modifier saleIsOpen() {
    require(_totalSupply() <= MAX_ELEMENTS, 'Sale end');
    if (_msgSender() != owner()) {
      require(!paused(), 'Pausable: paused');
    }
    _;
  }

  function _totalSupply() internal view returns (uint256) {
    return _tokenIdTracker.current();
  }

  function totalMint() public view returns (uint256) {
    return _totalSupply();
  }

  function mint(address _to) public payable saleIsOpen {
    uint256 total = _totalSupply();
    require(GameState.MINTING, "Minting is currently not allowed");
    require(balanceOf(_to) > 0, 'Only 1 per player');
    require(msg.value >= PRICE, 'Value below price');

    _mintAnElement(_to);
  }

  function _mintAnElement(address _to) private {
    uint256 id = _totalSupply();
    _tokenIdTracker.increment();
    _safeMint(_to, id);
  }

  function timeLeftInRound() public view returns(uint256){
    require(GameState.STARTED,"No rounds in progress");
    return roundTime - (block.timestamp - roundStartedAt);
  }

  function _baseURI() internal view virtual override returns (string memory) {
    return baseTokenURI;
  }

  function setBaseURI(string memory baseURI) public onlyOwner {
    baseTokenURI = baseURI;
  }

  function tokenURI(uint256 _tokenId) public view override returns (string memory) {
    return string(abi.encodePacked(baseTokenURI, Strings.toString(_tokenId)));
  }


  function walletOfOwner(address _owner) external view returns (uint256[] memory) {
    uint256 tokenCount = balanceOf(_owner);

    uint256[] memory tokensId = new uint256[](tokenCount);
    for (uint256 i = 0; i < tokenCount; i++) {
      tokensId[i] = tokenOfOwnerByIndex(_owner, i);
    }

    return tokensId;
  }

  function pause(bool val) public onlyOwner {
    if (val == true) {
      _pause();
      gameState = GameState.PREMINT;
    } else {
      _unpause();
      gameState = GameState.MINTING;
    }
  }

  // This is a last resort fail safe function.
  // If for any reason the contract doesn't sell out
  // or needs to be shutdown. This allows the administrators
  // to be able to to withdraw all funds from the contract
  // so that it can be disbursed back to the original minters
  function pullRug() public payable onlyOwner {
    uint256 balance = address(this).balance;
    require(balance > 0);
    _withdraw(owner(), address(this).balance);
  }

  function _withdraw(address _address, uint256 _amount) private {
    (bool success, ) = _address.call{value: _amount}('');
    require(success, 'Transfer failed');
  }

  function _withdrawOnSucess() {
      uint256 balance = address(this).balance; 
      uint256 winnerReward = SafeMath.mul(SafeMath.div(balance, 100), 100 - CREATOR_PERCENTAGE);
      uint256 creatorReward = SafeMath.mul(SafeMath.div(balance, 100), CREATOR_PERCENTAGE);

      if(creatorHasClaimed == false) {
        _withdraw(owner(), creatorReward);
        creatorHasClaimed = true;  
      }
      _withdraw(msg.sender, winnerReward);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 tokenId
  ) internal virtual override(ERC721, ERC721Enumerable, ERC721Pausable) {
    /* While the burn is happening, disable token transfers for all users
     *  other than the admin. The admin needs transfer privilages during
     *  the burn because burning is *technically* a transfer between owner
     *  of the NFT -> the NULL Address.
     **/
    if (_msgSender() != owner()) {
      require(currentRound == currentBurn, 'disabled');
    }

    super._beforeTokenTransfer(from, to, tokenId);
  }

  function startBurn() public onlyOwner {
    if (currentRound == 0) {
      require(totalSupply() == MAX_ELEMENTS, 'Not all tokens minted');
    }
    require(totalSupply() > 1, 'Game finished');
    _getRandomNumber();
  }

  /**
   * Claim winner:
   * - Requires creatorHasClaimed to be true
   * - Requires 1 token to be left
   * - Requires creator to have
   * - Withdraws the rest of the balance to contract owner
   */
  function claimWinnerReward() public {
    require(totalSupply() == 1 && GameState.FINISHED, 'Game not finished');
    require(creatorHasClaimed == true, 'Creator reward not claimed');
    require(_msgSender() == winnerAddress, 'Not winner');
    _withdrawOnSucess();
  }

  /**
   * Claim creator:
   * - Requires creatorHasClaimed to be false
   * - Withdraws CREATOR_PERCENTAGE / 100 * POT to contract owner
   * - Sets creatorHasClaimed to true
   */
  function claimCreatorReward() public onlyOwner {
    require(GameState.STARTED || GameState.FINISHED, "Minting is still underway");
    require(creatorHasClaimed == false, 'Creator reward claimed');
    uint256 balance = address(this).balance;
    uint256 creatorReward = SafeMath.mul(SafeMath.div(balance, 100), CREATOR_PERCENTAGE);
    _withdraw(owner(), creatorReward);
    creatorHasClaimed = true;
  }

  /**
   * Requests randomness
   */
  function _getRandomNumber() internal returns (bytes32 requestId) {
    require(LINK.balanceOf(address(this)) >= fee, 'Not enough LINK');
    // Increment the current burn
    currentBurn += 1;
    return requestRandomness(keyHash, fee);
  }

  /**
   * Callback function used by VRF Coordinator
   */
  function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
    randomResult = randomness;

    // Since Chainlink has provided a verifiably random value,
    // that can be used for the burn, let the admin burn the supply.
    _isAdminBurnEnabled = true;
  }

  uint256[] tokensToBurn;

  function burnSupply() public onlyOwner {
    require(_isAdminBurnEnabled, 'Burn disabled');
    require(totalSupply() > 1, 'Game is over');

    uint256 startingIndex = randomResult % 2;
    // The first burn should turn the game state to started.
    gameState = GameState.STARTED;

    uint256 currentSupplyLength = totalSupply();

    // Create an array of tokens to burn
    // (skipping every other item starting from startingIndex)
    for (uint256 index = startingIndex; index < currentSupplyLength; index += 2) {
      tokensToBurn.push(tokenByIndex(index));
    }
    // Burns all tokens in array
    for (uint256 i = 0; i < tokensToBurn.length; i++) {
      _burn(tokensToBurn[i]);
    }
    // Increment to the next round
    currentRound += 1;

    // If we have a winner, set the current winner field to the address
    // of the owner that owns the last remaining NFT.
    if (totalSupply() == 1) {
      winnerAddress = ownerOf(tokenByIndex(0));

      // Turn the game state to finished.
      gameState = GameState.FINISHED;
    }

    // clean up after yourself
    delete tokensToBurn;
    // After a burn is completed, disable the admin from
    // triggering another burn
    _isAdminBurnEnabled = false;
  }

  function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
    return super.supportsInterface(interfaceId);
  }
}