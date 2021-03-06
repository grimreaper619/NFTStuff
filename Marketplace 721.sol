// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";

/** @title NFT marketplace creation contract.
 */
contract Marketplace is AccessControl, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    /** Auction duration timestamp. */
    uint256 public biddingTime;

    /** Minimum auction duration timestamp. */
    uint256 public minBiddingTime;

    /** Maximum auction duration timestamp. */
    uint256 public maxBiddingTime;

    /** Counts total number of orders. */
    Counters.Counter private _numOrders;

    /** Address of the tokens used to pay for items. */
    mapping(address => bool) public acceptedTokens;

    /** Emitted when a new order is placed. */
    event PlacedOrder(
        uint256 indexed orderId,
        address itemContract,
        address token,
        uint256 indexed itemId,
        address indexed owner,
        uint256 basePrice
    );

    /** Emitted when an order is cancelled. */
    event CancelledOrder(uint256 indexed orderId, bool isSold);

    /** Emitted at the new highest bid. */
    event NewHighestBid(
        uint256 indexed orderId,
        address indexed maker,
        uint256 bidAmount
    );

    /** Emitted when the bidding time changes. */
    event BiddingTimeChanged(address from, uint256 newBiddingTime);

    /** Emitted when the auction is finished. */
    event AuctionFinished(uint256 indexed orderId, uint256 numBids);

    /** Emitted when a new purchase occures. */
    event Purchase(
        uint256 indexed orderId,
        address itemContract,
        uint256 indexed itemId,
        address maker,
        address taker,
        uint256 price
    );

    /**
     * @dev Checks if the given number is greater than zero.
     */
    modifier notZero(uint256 num) {
        require(num > 0, "Price & bid step can't be zero");
        _;
    }

    /** Order type: fixed price or auction. */
    enum OrderType {
        FixedPrice,
        Auction
    }

    /** Order struct. */
    struct Order {
        /** Item contract address. */
        address itemContract;
        /** Address of payment token */
        address token;
        /** Item id. */
        uint256 itemId;
        /** Base price in tokens. */
        uint256 basePrice;
        /** Listing timestamp. */
        uint256 listedAt;
        /** Expiration timestamp - 0 for fixed price. */
        uint256 expiresAt;
        /** Order status - set at cancellation. */
        bool isActive;
        /** Number of bids, always points to last (i.e. highest) bid. */
        uint256 numBids;
        /** Bid step in ACDM tokens. */
        uint256 bidStep;
        /** Maker address. */
        address maker;
        /** Order type. */
        OrderType orderType;
    }

    /** Bid struct. */
    struct Bid {
        /** Bid amount in ACDM tokens. */
        uint256 amount;
        /** Bidder address. */
        address bidder;
    }

    /** Orders by id. */
    mapping(uint256 => Order) public orders; // orderId => Order

    /** Bids by order and bid id. */
    mapping(uint256 => mapping(uint256 => Bid)) public bids; // orderId => bidId => Bid

    /** Stale time */
    uint256 private constant staleTime = 90 days;

    //Amount of time user should wait before auction refund
    uint256 private constant waitTime = 1 days;

    address public feeReceiver;
    uint16 public feePercent;

    /** @notice Creates marketplace contract.
     * @dev Grants `DEFAULT_ADMIN_ROLE` to `msg.sender`.
     * Grants `CREATOR_ROLE` to `_itemCreator`.
     * @param _biddingTime Initial bidding time.
     * @param _acceptedToken The address of the token used for payments.
     */
    constructor(
        uint256 _biddingTime,
        uint256 _minBiddingTime,
        uint256 _maxBiddingTime,
        address _acceptedToken
    ) {
        biddingTime = _biddingTime;
        minBiddingTime = _minBiddingTime;
        maxBiddingTime = _maxBiddingTime;

        acceptedTokens[_acceptedToken] = true;
        feeReceiver = msg.sender;
        feePercent = 100;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /** @notice Pausing some functions of contract.
    @dev Available only to admin.
    Prevents calls to functions with `whenNotPaused` modifier.
  */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /** @notice Unpausing functions of contract.
    @dev Available only to admin.
  */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /** @notice Changes bidding time.
     * @dev Available only to admin.
     *
     * Emits a {BiddingTimeChanged} event.
     *
     * @param _biddingTime New bidding time (timestamp).
     */
    function changeBiddingTime(uint256 _biddingTime)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            _biddingTime > minBiddingTime && _biddingTime < maxBiddingTime,
            "Time must be within the min and max"
        );
        biddingTime = _biddingTime;
        emit BiddingTimeChanged(msg.sender, _biddingTime);
    }

    /** @notice Changes accepted tokens.
     * @dev Available only to admin.
     *
     * Emits a {BiddingTimeChanged} event.
     *
     * @param _token Token to be changed.
     * @param _status whether added or removed.
     */
    function changeAcceptedTokens(address _token, bool _status)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        acceptedTokens[_token] = _status;
    }

    function changeFeeParams(address _newReceiver, uint16 _newPercent)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        feePercent = _newPercent;
        feeReceiver = _newReceiver;
    }

    function cancelStaleOrders(uint256[] memory orderId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order memory order = orders[orderId[i]];
            require(
                order.orderType == OrderType.FixedPrice,
                "Can't cancel an auction order"
            );
            if (order.listedAt + staleTime < block.timestamp) {
                _cancelOrder(orderId[i], false);
            }
        }
    }

    /** @notice Lists user item with a fixed price on the marketplace.
     *
     * Requirements:
     * - `basePrice` can't be zero.
     *
     * @param itemId Item ID.
     * @param basePrice Price of the item.
     */
    function listFixedPrice721(
        address itemContract,
        address token,
        uint256[] memory itemId,
        uint256 basePrice
    ) external whenNotPaused notZero(basePrice) {
        uint256 len = itemId.length;
        for (uint8 i = 0; i < len; i++) {
            _addOrder(
                itemContract,
                token,
                itemId[i],
                basePrice,
                0,
                OrderType.FixedPrice
            );
        }
    }

    /** @notice Lists user auction item on the marketplace.
     *
     * Requirements:
     * - `basePrice` can't be zero.
     * - `bidStep` can't be zero.
     *
     * @param itemId Item ID.
     * @param basePrice Price of the item.
     * @param bidStep Bid step.
     */
    function listAuction721(
        address itemContract,
        address token,
        uint256[] memory itemId,
        uint256 basePrice,
        uint256 bidStep
    ) external whenNotPaused notZero(basePrice) notZero(bidStep) {
        uint256 len = itemId.length;
        for (uint8 i = 0; i < len; i++) {
            _addOrder(
                itemContract,
                token,
                itemId[i],
                basePrice,
                bidStep,
                OrderType.Auction
            );
        }
    }

    /** @notice Allows user to buy an item from an order with a fixed price.
     * @param orderId Order IDs.
     */
    function buyOrder(uint256[] memory orderId) external whenNotPaused {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order memory order = orders[orderId[i]];
            require(
                order.basePrice > 0 && order.isActive,
                "Order cancelled or not exist"
            );
            require(
                order.orderType == OrderType.FixedPrice,
                "Can't buy auction order"
            );
            require(msg.sender != order.maker, "Can't buy from yourself");

            // Transfer NFT to `msg.sender` and token to order maker
            _exchange(
                orderId[i],
                order.itemContract,
                order.itemId,
                order.basePrice,
                msg.sender,
                order.maker,
                msg.sender
            );

            _cancelOrder(orderId[i], true);
        }
    }

    /** @notice Allows user to bid on an auction.
     *
     * Requirements:
     * - `bidAmount` must be higher than the last bid + bid step.
     *
     * @param orderId Order ID.
     * @param bidAmount Amount in ACDM tokens.
     */
    function makeBid(uint256[] memory orderId, uint256[] memory bidAmount)
        external
        whenNotPaused
    {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order storage order = orders[orderId[i]];
            require(order.expiresAt > block.timestamp, "Bidding time is over");
            require(msg.sender != order.maker, "Can't bid on your own order");

            uint256 numBids = order.numBids;
            Bid storage lastBid = bids[orderId[i]][numBids];
            require(
                bidAmount[i] > (order.basePrice + order.bidStep) &&
                    bidAmount[i] > (lastBid.amount + order.bidStep),
                "Bid must be more than highest + bid step"
            );

            // Transfer ACDM tokens
            _transferTokens(
                order.token,
                msg.sender,
                address(this),
                lastBid.bidder == msg.sender
                    ? (bidAmount[i] - lastBid.amount)
                    : bidAmount[i]
            );

            // Return ACDM to the last bidder
            if (numBids > 0 && lastBid.bidder != msg.sender)
                _transferTokens(
                    order.token,
                    address(0),
                    lastBid.bidder,
                    lastBid.amount
                );

            order.numBids++;
            bids[orderId[i]][order.numBids] = Bid({
                amount: bidAmount[i],
                bidder: msg.sender
            });

            emit NewHighestBid(orderId[i], msg.sender, bidAmount[i]);
        }
    }

    /** @notice Allows user to cancel an order with a fixed price.
     *
     * Requirements:
     * - `msg.sender` must be the creator of the order.
     *
     * @param orderId Order ID.
     */
    function cancelOrder(uint256[] memory orderId) external whenNotPaused {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order memory order = orders[orderId[i]];
            require(msg.sender == order.maker, "Not the order creator");
            require(
                order.orderType == OrderType.FixedPrice,
                "Can't cancel an auction order"
            );

            _cancelOrder(orderId[i], false);
        }
    }

    /** @notice Allows user to refund an order within auction.
     *
     * Requirements:
     * - `msg.sender` must be the creator of the order.
     * - user must wait one day to claim refund
     *
     * @param orderId Order ID.
     */
    function refundAuction(uint256[] memory orderId) external whenNotPaused {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order memory order = orders[orderId[i]];
            uint256 numBids = order.numBids;
            Bid memory lastBid = bids[orderId[i]][numBids];

            require(order.orderType == OrderType.Auction, "Not auction");
            require(order.isActive, "No such order");
            require(
                order.expiresAt + waitTime < block.timestamp,
                "Not refundable yet"
            );
            require(msg.sender == lastBid.bidder, "Not the last bidder");

            _transferTokens(
                order.token,
                address(0),
                lastBid.bidder,
                lastBid.amount
            );
            _cancelOrder(orderId[i], false);
        }
    }

    /** @notice Allows user to finish the auction.
     *
     * Requirements:
     * - `order.expiresAt` must be greater than the current timestamp (`block.timestamp`).
     *
     * @param orderId Order ID.
     */
    function finishAuction(uint256[] memory orderId) external whenNotPaused {
        uint256 len = orderId.length;
        for (uint8 i = 0; i < len; i++) {
            Order storage order = orders[orderId[i]];
            uint256 numBids = order.numBids;
            Bid storage lastBid = bids[orderId[i]][numBids];

            require(order.isActive, "No such order");
            require(msg.sender == order.maker || msg.sender == lastBid.bidder, "No permission");
            require(
                order.orderType == OrderType.Auction,
                "Not an auction order"
            );
            require(
                order.expiresAt <= block.timestamp,
                "Can't finish before bidding time"
            );
            if (numBids > 2) {
                _exchange(
                    orderId[i],
                    order.itemContract,
                    order.itemId,
                    lastBid.amount,
                    address(0),
                    order.maker,
                    lastBid.bidder
                );
                _cancelOrder(orderId[i], true);
            } else {
                // Return ACDM to the last bidder
                if (numBids > 0)
                    _transferTokens(
                        order.token,
                        address(0),
                        lastBid.bidder,
                        lastBid.amount
                    );
                _cancelOrder(orderId[i], false);
            }

            emit AuctionFinished(orderId[i], numBids);
        }
    }

    /** @notice Adds new order to the marketplace.
     *
     * Emits a {PlacedOrder} event.
     *
     * @param itemContract Item contract address.
     * @param itemId Item ID.
     * @param basePrice Price of the item.
     * @param bidStep Bid step.
     * @param orderType Order type (see `OrderType` enum).
     */
    function _addOrder(
        address itemContract,
        address token,
        uint256 itemId,
        uint256 basePrice,
        uint256 bidStep,
        OrderType orderType
    ) private {
        _numOrders.increment();
        uint256 numOrders = _numOrders.current();

        Order storage order = orders[numOrders];
        order.isActive = true;
        order.itemContract = itemContract;
        order.itemId = itemId;
        order.basePrice = basePrice;
        order.listedAt = block.timestamp;
        order.maker = msg.sender;
        order.orderType = orderType;
        order.token = token;

        if (orderType == OrderType.Auction) {
            order.expiresAt = block.timestamp + biddingTime;
            order.bidStep = bidStep;
        }

        require(
            IERC721(itemContract).ownerOf(itemId) == order.maker,
            "ERC721 token does not belong to the author."
        );

        emit PlacedOrder(
            numOrders,
            itemContract,
            token,
            itemId,
            msg.sender,
            basePrice
        );
    }

    /** @notice Exchanges ACDM tokens and Items between users.
     * @dev `payer` here is either `itemRecipient` or `address(0)`
     * which means that we should transfer ACDM from the contract.
     *
     * @param orderId Order ID.
     * @param itemContract Item contract address.
     * @param itemId Item ID.
     * @param price Item price in ACDM tokens.
     * @param payer Address of the payer.
     * @param itemOwner Address of the item owner.
     * @param itemRecipient Address of the item recipient.
     */
    function _exchange(
        uint256 orderId,
        address itemContract,
        uint256 itemId,
        uint256 price,
        address payer,
        address itemOwner,
        address itemRecipient
    ) private {
        if (feePercent > 0) {
            uint256 feeAmount = (price * feePercent) / 1000;
            _transferTokens(
                orders[orderId].token,
                payer,
                feeReceiver,
                feeAmount
            );
            price = price - feeAmount;
        }

        _transferTokens(orders[orderId].token, payer, itemOwner, price);

        require(
            IERC721(itemContract).getApproved(itemId) == address(this),
            "Asset not owned by this listing. Probably was already sold."
        );
        IERC721(itemContract).safeTransferFrom(
            orders[orderId].maker,
            itemRecipient,
            itemId
        );

        emit Purchase(
            orderId,
            itemContract,
            itemId,
            itemOwner,
            itemRecipient,
            price
        );
    }

    /** @notice Transfers tokens between users.
     * @param from The address to transfer from.
     * @param to The address to transfer to.
     * @param amount Transfer amount in ACDM tokens.
     */
    function _transferTokens(
        address token,
        address from,
        address to,
        uint256 amount
    ) private {
        from != address(0)
            ? IERC20(token).safeTransferFrom(from, to, amount)
            : IERC20(token).safeTransfer(to, amount);
    }

    /** @notice Cancelling order by id.
     * @param orderId Order ID.
     * @param isSold Indicates wheter order was purchased or simply cancelled by the owner.
     */
    function _cancelOrder(uint256 orderId, bool isSold) private {
        Order storage order = orders[orderId];
        order.isActive = false;
        emit CancelledOrder(orderId, isSold);
    }

    /** @notice Checks if item is currently listed on the marketplace.
     * @param itemContract Item contract address.
     * @param itemId Item ID.
     * @return boob Whether the item in an open order.
     */
    function isListed(address itemContract, uint256 itemId)
        external
        view
        returns (bool)
    {
        uint256 numOrders = _numOrders.current();
        for (uint256 i = 1; i <= numOrders; i++) {
            if (
                orders[i].isActive &&
                orders[i].itemId == itemId &&
                orders[i].itemContract == itemContract
            ) return true;
        }
        return false;
    }

    /** @notice Returns the entire order history on the market.
     * @return Array of `Order` structs.
     */
    function getOrdersHistory() external view returns (Order[] memory) {
        uint256 numOrders = _numOrders.current();
        Order[] memory ordersArr = new Order[](numOrders);

        for (uint256 i = 1; i <= numOrders; i++) {
            ordersArr[i - 1] = orders[i];
        }
        return ordersArr;
    }

    /** @notice Returns current open orders on the market.
     * @return Array of `Order` structs.
     */
    function getOpenOrders()
        external
        view
        returns (Order[] memory, uint256[] memory)
    {
        Order[] memory openOrders = new Order[](countOpenOrders());
        uint256[] memory openIds = new uint256[](countOpenOrders());
        uint256 counter;
        uint256 numOrders = _numOrders.current();
        for (uint256 i = 1; i <= numOrders; i++) {
            if (orders[i].isActive) {
                openOrders[counter] = orders[i];
                openIds[counter] = i;
                counter++;
            }
        }
        return (openOrders, openIds);
    }

    /** @notice Counts currently open orders.
     * @return numOpenOrders Number of open orders.
     */
    function countOpenOrders() public view returns (uint256 numOpenOrders) {
        uint256 numOrders = _numOrders.current();
        for (uint256 i = 1; i <= numOrders; i++) {
            if (orders[i].isActive) {
                numOpenOrders++;
            }
        }
    }

    /** @notice Returns all marketplace bids sorted by orders.
     * @return Array of arrays (`Bid` structs array by each order).
     */
    function getBidsHistory() external view returns (Bid[][] memory) {
        uint256 numOrders = _numOrders.current();
        Bid[][] memory bidsHistory = new Bid[][](numOrders);

        for (uint256 i = 1; i <= numOrders; i++) {
            bidsHistory[i - 1] = getBidsByOrder(i);
        }

        return bidsHistory;
    }

    /** @notice Returns all bids by order id.
     * @param orderId Order ID.
     * @return Array of `Bid` structs.
     */
    function getBidsByOrder(uint256 orderId)
        public
        view
        returns (Bid[] memory)
    {
        uint256 numBids = orders[orderId].numBids;
        Bid[] memory orderBids = new Bid[](numBids);

        for (uint256 i = 1; i <= numBids; i++) {
            orderBids[i - 1] = bids[orderId][i];
        }

        return orderBids;
    }

    /** Always returns `IERC721Receiver.onERC721Received.selector`. */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
