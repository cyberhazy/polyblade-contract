// Define version of Solidity in use
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

/**
 * The real 🗡️ PolyBlade 🗡️ smart contract!
 * Smithed with 3D software, coated with computer-generated paint,
 * forged as an NFT and served via the decentralized web!
 *
 * The contract ensures a fair random distribution by making use of Chainlink's VRF
 * to grant tokens to the minters. Powered by IPFS to keep it distributed!
 *
 * Various owner/dev features are present in case things go wrong with the contract:
 * pausing the contract in case of vulnerabilities/issues, pausing sale in case of
 * delays or vulnerabilities in fair distribution, emergency fulfilling randomness
 * in case things go wrong with the VRF functionality.
 *
 * Discounting & dev minting functionality is reserved for giveaways and rare discount
 * events, as well as compensation in the case of devmint. Reserve/claim is added
 * to reward OG PolyBlade V0 holders.
 *
 * The contract usage is as follows:
 * Construct ->
 * Init mint to max supply (over split txes if needed) ->
 * Disable pause (if enabled) ->
 * Enable sale (if disabled)
 * (by default, sale is enabled and pause is disabled)
 *
 * Brought to you by PolyForge🔥⚔️
 */
contract PolyBlade is ERC721Enumerable, Ownable, Pausable, VRFConsumerBase {
    using SafeMath for uint256;
    using SafeMath for uint16;

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    address public immutable oldPolybladeAddress; // Old PolyBlade address (used for claim)
    uint256 public immutable fixedPrice; // Fixed price w/o discount
    uint16 public immutable maxSupply;

    /**
     * Counter for mints remaining.
     *  While _mintIndices.length represents a similar value, it is not
     *  equal to the mints remaining in the case where random fulfillment is\
     *  pending.
     */
    uint16 public mintsRemaining;

    uint16 public discountedMintsRemaining; // Number of mints remaining after which price resets to fixed
    uint256 public price; // Dynamic price that can be discounted
    uint256 public saleStart; // Block at which sale starts
    bool public isSaleActive; // Toggle for sale on/off

    bytes32 internal _linkKeyHash;
    uint256 internal _linkFee;

    uint16[] private _mintIndices; // Indices of tokens that are yet to be minted
    bool private _mintInitialized; // Keep track whether the mint indices array is initialized
    // Reserved indices for converting old Poly Blades to new ones. Maps old token ID -> mint amount
    mapping(uint256 => uint16) private _reservedIndices;
    mapping(bytes32 => address) private _linkRequests; // Link mint requests -> recipient map

    /** Event on request randomness call */
    event RequestMint(bytes32 indexed requestId);

    /** Event on fulfill randomness call */
    event FulfillMint(bytes32 indexed requestId, uint256 token);

    /**
     * @dev Throws if sale not active
     */
    modifier whenSaleActive() {
        require(
            block.timestamp >= saleStart,
            "Sale of the token is not yet active"
        );
        require(isSaleActive, "Sale of the token is disabled");
        _;
    }

    /**
     * @dev throws if minting is not initialized fully
     */
    modifier whenMintInitialized() {
        require(_mintInitialized, "Minting not yet initialized");
        _;
    }

    constructor(
        uint16 initMaxSupply,
        uint256 initSaleStart,
        uint256 initFixedPrice,
        address initOldAddress,
        address vrfCoordinator,
        address linkToken,
        bytes32 keyHash
    )
        ERC721("PolyBlade", "POLYBLADE")
        VRFConsumerBase(vrfCoordinator, linkToken)
    {
        maxSupply = initMaxSupply;
        mintsRemaining = initMaxSupply;
        saleStart = initSaleStart;
        fixedPrice = initFixedPrice;
        price = initFixedPrice;
        oldPolybladeAddress = initOldAddress;

        _linkKeyHash = keyHash;
        _linkFee = 0.0001 * 10**18;
        isSaleActive = true;
    }

    /**
     * Pay & mint multiple tokens.
     * Reverts when there is a discount active to encourage single mints.
     */
    function batchMint(uint16 mintCount)
        external
        payable
        whenMintInitialized
        whenNotPaused
        whenSaleActive
    {
        require(
            mintsRemaining >= mintCount,
            "Mint count exceeds available mint count"
        );
        require(mintCount <= 5, "Cannot batch mint more than 5 tokens at once");
        require(mintCount > 0, "Must mint at least 1 token!");
        require(
            discountedMintsRemaining == 0,
            "Cannot batch mint when discount is in effect"
        );
        require(msg.value >= mintCount * price, "Insufficient payment amount!");

        for (uint16 i = 0; i < mintCount; ++i) {
            mint();
        }
    }

    /**
     * @dev Burns `tokenId`. See {ERC721-_burn}.
     *
     * Requirements:
     *
     * - The caller must own `tokenId` or be an approved operator.
     */
    function burn(uint256 tokenId)
        external
        virtual
        whenMintInitialized
        whenNotPaused
    {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "ERC721Burnable: caller is not owner nor approved"
        );
        _burn(tokenId);
    }

    /**
     * Claim new Poly Blades by burning a token of the old contract.
     * The tokenId must first be reserved via the `reserveClaim` function.
     */
    function claim(uint256 tokenId)
        external
        whenMintInitialized
        whenNotPaused
        whenSaleActive
    {
        require(
            IERC721(oldPolybladeAddress).ownerOf(tokenId) == msg.sender,
            "Sender does not own the specified token ID."
        );
        require(
            _reservedIndices[tokenId] != 0,
            "The given token ID cannot be claimed"
        );

        // Trigger mint. Assumes that mintsRemaining is already decremented
        // in the reserve claim and thus does not alter the mints remaining state.
        for (uint16 i = 0; i < _reservedIndices[tokenId]; ++i) {
            _requestRandomMint(msg.sender);
        }

        // Clear from storage
        delete _reservedIndices[tokenId];

        // Burn old token
        IERC721(oldPolybladeAddress).transferFrom(
            msg.sender,
            BURN_ADDRESS,
            tokenId
        );
    }

    /**
     * Reserves claim for old Poly Blade token burn claims.
     */
    function reserveClaim(uint256 tokenId, uint16 reserveCount)
        external
        whenMintInitialized
        whenNotPaused
        onlyOwner
    {
        require(
            _reservedIndices[tokenId] == 0,
            "The given token ID is already reserved"
        );
        require(reserveCount != 0, "Must reserve at least 1 token");
        require(reserveCount <= 4, "Cannot reserve more than 4 tokens!");
        require(
            IERC721(oldPolybladeAddress).ownerOf(tokenId) != address(0),
            "Token ID must exist on old contract!"
        );
        require(
            IERC721(oldPolybladeAddress).ownerOf(tokenId) != BURN_ADDRESS,
            "Token ID on old contract must not be burned!"
        );
        require(
            mintsRemaining >= reserveCount,
            "Cannot reserve more than remaining supply!"
        );

        mintsRemaining -= reserveCount;
        _reservedIndices[tokenId] = reserveCount;
    }

    /**
     * Unreserves claim for old Poly Blade token.
     */
    function unreserveClaim(uint256 tokenId)
        external
        whenMintInitialized
        whenNotPaused
        onlyOwner
    {
        require(
            _reservedIndices[tokenId] != 0,
            "The given token ID must be reserved"
        );

        mintsRemaining += _reservedIndices[tokenId];
        delete _reservedIndices[tokenId];
    }

    /**
     * Mint a non-minted token to a recipient without cost (only by the owner)
     */
    function devMint(address recipient, uint256 tokenId)
        external
        whenMintInitialized
        whenNotPaused
        onlyOwner
    {
        _mintToken(recipient, tokenId);
    }

    /**
     * Mints a random non-minted token to a recipient without cost (only by the owner)
     */
    function devMintRandom(address recipient)
        external
        whenMintInitialized
        whenNotPaused
        onlyOwner
    {
        _mintRandomToken(recipient);
    }

    /**
     * Initializes mint indices array. Used to split gas costs into a separate
     * function (as it is too expensive for the constructor)
     */
    function initializeMint(uint16 startId, uint16 endId) public onlyOwner {
        require(startId <= endId, "Start ID must not exceed endId!");
        require(endId < maxSupply, "End ID cannot exceed max supply!");
        require(startId >= _mintIndices.length, "Cannot re-add the same IDs!");
        require(
            (_mintIndices.length == 0 && startId == 0) || // First add
                (_mintIndices.length != 0 &&
                    startId == _mintIndices[_mintIndices.length - 1] + 1),
            "Can only add new mint ID in sequence!"
        );
        require(!_mintInitialized, "Minting already initialized!");

        for (uint16 i = startId; i <= endId; ++i) {
            _mintIndices.push(i);
        }

        if (_mintIndices.length == maxSupply) {
            _mintInitialized = true;
        }
    }

    /**
     * Pay & mint token
     */
    function mint()
        public
        payable
        whenMintInitialized
        whenNotPaused
        whenSaleActive
    {
        // Reset discounted price to fixed price when no more discount mints remain
        if (discountedMintsRemaining <= 0) {
            price = fixedPrice;
        } else {
            discountedMintsRemaining -= 1;
        }

        // Verify the price is right
        require(msg.value >= price, "Insufficient payment amount!");

        // When the number of mints discounted turns to 0, the price
        // should also be updated after the price check in order to
        // reflect accurate price info to the next minter.
        if (discountedMintsRemaining <= 0) {
            price = fixedPrice;
        }

        _mintRandomToken(msg.sender);
    }

    /**
     * Adjust price for a discounted number of mints.
     * Do not allow decreasing the price.
     * Calling with numberOfMints = 0 will reset to the original fixed price.
     */
    function discountMintPrice(uint256 newPrice, uint16 numberOfMints)
        public
        whenMintInitialized
        whenNotPaused
        onlyOwner
    {
        require(
            newPrice <= fixedPrice,
            "New price cannot be larger than the fixed price"
        );
        require(
            newPrice != fixedPrice || numberOfMints == 0,
            "New price must be different from fixed price"
        );

        discountedMintsRemaining = numberOfMints;

        if (numberOfMints == 0) {
            price = fixedPrice;
        } else {
            price = newPrice;
        }
    }

    /**
     * Withdraw funds in contract
     */
    function withdraw() public onlyOwner {
        require(
            address(this).balance > 0,
            "Funds must be present in order to withdraw!"
        );
        payable(msg.sender).transfer(address(this).balance);
    }

    /**
     * Withdraws ERC-20 token funds in contract
     */
    function withdrawErc20(address tokenAddress) public onlyOwner {
        IERC20 tokenContract = IERC20(tokenAddress);
        uint256 balance = tokenContract.balanceOf(address(this));
        require(balance > 0, "Funds must be present in order to withdraw!");
        tokenContract.transfer(msg.sender, balance);
    }

    /**
     * Updates LINK fee for VRF usage
     */
    function updateLinkFee(uint256 newFee) public onlyOwner {
        _linkFee = newFee;
    }

    /**
     * Emergency manual fulfillment if fulfillRandomness fails for some reason.
     * Should only be used with real VRF randomness value, if it is recoverable.
     */
    function emergencyFulfill(bytes32 requestId, uint256 randomness)
        external
        whenMintInitialized
        onlyOwner
    {
        require(
            _linkRequests[requestId] != address(0),
            "Request must be present!"
        );
        fulfillRandomness(requestId, randomness);
    }

    /**
     * Toggle sale on/off
     */
    function toggleSale(bool toggle) public onlyOwner {
        isSaleActive = toggle;
    }

    /**
     * Sets a new date for the sale of NFTs
     */
    function setSaleStart(uint256 newSaleStart) public onlyOwner {
        saleStart = newSaleStart;
    }

    /**
     * Toggles pause on/off
     */
    function togglePause(bool toggle) public onlyOwner {
        if (toggle) {
            _pause();
        } else {
            _unpause();
        }
    }

    /**
     * Fulfills randomness by executing a mint using the retrieved random seed.
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        address recipient = _linkRequests[requestId];

        if (recipient != address(0) && _mintIndices.length > 0) {
            // Pick random entry in _mintIndices state, retrieve & remove token ID
            uint256 randomId = randomness % _mintIndices.length;
            uint256 tokenId = _removeMintId(randomId);

            // Mint & remove request to mark as satisfied
            _safeMint(recipient, tokenId);
            delete _linkRequests[requestId];
            emit FulfillMint(requestId, tokenId);
        }
    }

    /**
     * @dev See {ERC721-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - the contract must not be paused.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);

        require(!paused(), "Cannot transfer tokens while contract is paused.");
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return "ipfs://QmTkzMGeiC7Rss7G7jmPsoHZT2TrqsnCH2EWiuGNnCqPDX/";
    }

    /**
     * Requests a random mint to target recipient.
     * Does **not** check or change mints remaining state!
     */
    function _requestRandomMint(address recipient) private {
        // VRF mint request. Mint callback expected in fulfillRandomness
        bytes32 requestId = requestRandomness(_linkKeyHash, _linkFee);
        _linkRequests[requestId] = recipient;
        emit RequestMint(requestId);
    }

    /**
     * Initiates a random token mint to the target recipient
     */
    function _mintRandomToken(address recipient) private {
        require(mintsRemaining > 0, "No more mints remaining!");
        require(
            LINK.balanceOf(address(this)) >= _linkFee,
            "Insufficient LINK. Dev should fix this soon!"
        );

        mintsRemaining--;
        _requestRandomMint(recipient);
    }

    /**
     * Mints a specific token ID to the recipient.
     * Decrements the mints remaining.
     */
    function _mintToken(address recipient, uint256 id) private {
        require(!_exists(id), "Token already minted!");
        require(mintsRemaining > 0, "No more mints remaining!");

        mintsRemaining--;
        _removeTokenId(id);
        _safeMint(recipient, id);
    }

    /**
     * Remove the specified token ID value from '_mintIndices'.
     * Decrements the mints remaining.
     */
    function _removeTokenId(uint256 value) private {
        uint256 notFoundIndex = maxSupply + 1337;
        uint256 foundIndex = notFoundIndex;

        for (uint256 i = 0; i < _mintIndices.length; ++i) {
            if (_mintIndices[i] == value) {
                foundIndex = i;
                break;
            }
        }

        require(
            foundIndex != notFoundIndex,
            "Token to be removed could not be found!"
        );
        _removeMintId(foundIndex);
    }

    /**
     * Removes the value specified at **index** from '_mintIndices'.
     * Shrinks the array.
     */
    function _removeMintId(uint256 index) private returns (uint256) {
        // Swap last value & now-removed mint index position in the array
        uint256 lastIndex = _mintIndices.length - 1;
        uint16 indexValue = _mintIndices[index];

        _mintIndices[index] = _mintIndices[lastIndex];
        _mintIndices[lastIndex] = indexValue;

        // Shrink array
        delete _mintIndices[lastIndex];
        _mintIndices.pop();

        return indexValue;
    }
}
