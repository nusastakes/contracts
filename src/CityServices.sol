// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ApyFeed} from "./ApyFeed.sol";
import {ICityFactory} from "./interfaces/ICityFactory.sol";
import {ICityVault} from "./interfaces/ICityVault.sol";

/// @notice Fixed-supply token created by the launchpad service. The whole supply starts on the bonding curve.
contract CityToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address holder) ERC20(name_, symbol_) {
        _mint(holder, supply);
    }
}

/// @notice Ready-to-use services that a mayor switches on for OUTSIDE users of the city: a token launchpad with a
/// bonding curve, and prediction markets on the APY of a Monad protocol (read from `ApyFeed`). Every use pays a
/// service fee in the city's asset to the city vault, which raises the share price: residents earn it, and the mayor
/// only earns through the usual performance fee on that profit. No markup goes to the mayor directly.
/// @dev Fees are streamed into the vault over about `dripPeriod` instead of landing at once, so nobody can deposit
/// just before a large fee and withdraw right after it to take most of it from the residents.
/// @dev One contract serves every city of one factory. A city must be a vault of that factory; only its mayor can
/// switch services on or off and open markets. Trading and claiming never depend on the service still being on, so
/// users can always exit.
contract CityServices is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant LAUNCHPAD = 1;
    uint8 public constant PREDICTION = 2;

    /// @notice Upper bound of the fee a mayor can charge on a service, in basis points of the volume.
    uint16 public constant MAX_FEE_BPS = 300;
    /// @notice Flat fee for launching a token, paid to the city (1 unit of a 6-decimal asset = 1 AUSD).
    uint256 public immutable launchFee;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    /// @notice Virtual asset reserve of every curve: sets the starting price (VIRTUAL / TOKEN_SUPPLY per token).
    uint256 public immutable virtualReserve;

    uint64 public constant MIN_MARKET_TIME = 5 minutes;
    uint64 public constant MAX_MARKET_TIME = 30 days;
    /// @notice Smallest gap between the end of betting and the measurement, so a bet cannot simply copy the rate
    /// that is about to be measured.
    uint64 public constant MIN_MEASURE_GAP = 5 minutes;
    /// @notice After this long past the measurement time without a feed update, anyone may void the market.
    uint64 public constant VOID_AFTER = 3 days;
    /// @notice Time constant of the fee stream into a city vault.
    uint64 public immutable dripPeriod;
    /// @notice Whether mayors may switch prediction markets on. Fixed at deployment; the platform can hold the
    /// service back (for example until its legal review) without touching the launchpad.
    bool public immutable predictionEnabled;

    IERC20 public immutable asset;
    ICityFactory public immutable factory;
    ApyFeed public immutable feed;

    struct Service {
        bool on;
        uint16 feeBps;
    }

    struct Stats {
        uint128 volume;
        uint128 fees;
        uint64 uses;
    }

    struct Drip {
        uint128 pending;
        uint64 last;
    }

    struct Curve {
        address city;
        uint256 reserve; // real asset held for this token
        uint256 tokens; // tokens still on the curve
    }

    enum Outcome {
        Open,
        Above,
        Below,
        Void
    }

    struct Market {
        address city;
        bytes32 sourceId;
        uint32 thresholdBps;
        uint64 closesAt;
        uint64 resolvesAt;
        Outcome outcome;
        uint32 resolvedApyBps;
        uint256 poolAbove;
        uint256 poolBelow;
    }

    mapping(address city => mapping(uint8 kind => Service)) public services;
    mapping(address city => mapping(uint8 kind => Stats)) public stats;
    mapping(address city => Drip) public drips;
    mapping(address token => Curve) public curves;
    mapping(address city => address[]) internal _tokens;

    Market[] internal _markets;
    mapping(address city => uint256[]) internal _cityMarkets;
    mapping(uint256 id => mapping(address user => uint256)) public stakeAbove;
    mapping(uint256 id => mapping(address user => uint256)) public stakeBelow;
    mapping(uint256 id => mapping(address user => bool)) public claimed;

    event ServiceSet(address indexed city, uint8 indexed kind, bool on, uint16 feeBps);
    event ServiceUsed(address indexed city, uint8 indexed kind, address indexed user, uint256 volume, uint256 fee);
    event TokenLaunched(address indexed city, address indexed token, address indexed creator, string name, string symbol);
    event Traded(
        address indexed city, address indexed token, address indexed user, bool buy, uint256 ausd, uint256 tokens, uint256 fee
    );
    event FeesReleased(address indexed city, uint256 amount);
    event MarketOpened(
        uint256 indexed id,
        address indexed city,
        bytes32 indexed sourceId,
        uint32 thresholdBps,
        uint64 closesAt,
        uint64 resolvesAt
    );
    event Predicted(uint256 indexed id, address indexed user, bool above, uint256 amount, uint256 fee);
    event MarketResolved(uint256 indexed id, uint8 outcome, uint32 apyBps);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);

    error NotCity(address city);
    error NotMayor();
    error UnknownKind(uint8 kind);
    error FeeTooHigh(uint16 feeBps);
    error ServiceOff(address city, uint8 kind);
    error BadName();
    error UnknownToken(address token);
    error ZeroAmount();
    error Slippage(uint256 out, uint256 minOut);
    error BadCloseTime(uint64 closesAt, uint64 resolvesAt);
    error NoFeedData(bytes32 sourceId);
    error UnknownMarket(uint256 id);
    error MarketClosed(uint256 id);
    error MarketNotClosed(uint256 id);
    error AlreadyResolved(uint256 id);
    error NoObservationAfterClose(uint256 id);
    error TooEarlyToVoid(uint256 id);
    error NothingToClaim(uint256 id);

    constructor(
        IERC20 asset_,
        ICityFactory factory_,
        ApyFeed feed_,
        uint256 launchFee_,
        uint256 virtualReserve_,
        uint64 dripPeriod_,
        bool predictionEnabled_
    ) {
        asset = asset_;
        factory = factory_;
        feed = feed_;
        launchFee = launchFee_;
        virtualReserve = virtualReserve_;
        dripPeriod = dripPeriod_;
        predictionEnabled = predictionEnabled_;
    }

    // ---------------------------------------------------------------- mayor

    /// @notice The mayor switches a service on or off for the city and sets its fee (at most `MAX_FEE_BPS`).
    function setService(address city, uint8 kind, bool on, uint16 feeBps) external {
        _onlyMayor(city);
        if (kind != LAUNCHPAD && (kind != PREDICTION || !predictionEnabled)) revert UnknownKind(kind);
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);
        services[city][kind] = Service(on, feeBps);
        emit ServiceSet(city, kind, on, feeBps);
    }

    /// @notice The mayor opens a market: "will the APY of `sourceId` be above `thresholdBps` at `resolvesAt`?".
    /// Betting stops at `closesAt`, at least `MIN_MEASURE_GAP` before the measurement. It resolves from `ApyFeed`
    /// only, so the mayor cannot decide the outcome.
    function openMarket(address city, bytes32 sourceId, uint32 thresholdBps, uint64 closesAt, uint64 resolvesAt)
        external
        returns (uint256 id)
    {
        _onlyMayor(city);
        if (!services[city][PREDICTION].on) revert ServiceOff(city, PREDICTION);
        if (
            closesAt < block.timestamp + MIN_MARKET_TIME || resolvesAt < closesAt + MIN_MEASURE_GAP
                || resolvesAt > block.timestamp + MAX_MARKET_TIME
        ) revert BadCloseTime(closesAt, resolvesAt);
        (,, uint64 updatedAt) = feed.latest(sourceId);
        if (updatedAt == 0) revert NoFeedData(sourceId);
        id = _markets.length;
        _markets.push(Market(city, sourceId, thresholdBps, closesAt, resolvesAt, Outcome.Open, 0, 0, 0));
        _cityMarkets[city].push(id);
        emit MarketOpened(id, city, sourceId, thresholdBps, closesAt, resolvesAt);
    }

    // ---------------------------------------------------------------- launchpad

    /// @notice Launches a token on the city's launchpad. The caller pays `launchFee` to the city; the full supply
    /// sits on a bonding curve, and `buyAmount` (optional) buys the first tokens in the same call.
    function launch(address city, string calldata name, string calldata symbol, uint256 buyAmount, uint256 minTokens)
        external
        nonReentrant
        returns (address token, uint256 tokensOut)
    {
        if (!services[city][LAUNCHPAD].on) revert ServiceOff(city, LAUNCHPAD);
        uint256 nl = bytes(name).length;
        uint256 sl = bytes(symbol).length;
        if (nl == 0 || nl > 32 || sl == 0 || sl > 8) revert BadName();

        if (launchFee > 0) {
            asset.safeTransferFrom(msg.sender, address(this), launchFee);
            _payCity(city, launchFee);
        }
        _record(city, LAUNCHPAD, launchFee, launchFee);

        token = address(new CityToken(name, symbol, TOKEN_SUPPLY, address(this)));
        curves[token] = Curve(city, 0, TOKEN_SUPPLY);
        _tokens[city].push(token);
        emit TokenLaunched(city, token, msg.sender, name, symbol);

        if (buyAmount > 0) tokensOut = _buy(token, buyAmount, minTokens);
    }

    /// @notice Buys tokens of a launched token with the city asset. A fee of the city's launchpad rate goes to the city.
    function buy(address token, uint256 amount, uint256 minTokens) external nonReentrant returns (uint256 tokensOut) {
        tokensOut = _buy(token, amount, minTokens);
    }

    /// @notice Sells tokens back to the curve for the city asset, minus the city's launchpad fee.
    function sell(address token, uint256 tokensIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.city == address(0)) revert UnknownToken(token);
        if (tokensIn == 0) revert ZeroAmount();
        uint256 gross = _sellQuote(c, tokensIn);
        uint256 fee = gross * services[c.city][LAUNCHPAD].feeBps / 10_000;
        out = gross - fee;
        if (out < minOut) revert Slippage(out, minOut);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        c.tokens += tokensIn;
        c.reserve -= gross;
        if (fee > 0) _payCity(c.city, fee);
        asset.safeTransfer(msg.sender, out);
        _record(c.city, LAUNCHPAD, gross, fee);
        emit Traded(c.city, token, msg.sender, false, gross, tokensIn, fee);
    }

    function quoteBuy(address token, uint256 amount) external view returns (uint256 tokensOut, uint256 fee) {
        Curve storage c = curves[token];
        if (c.city == address(0)) revert UnknownToken(token);
        fee = amount * services[c.city][LAUNCHPAD].feeBps / 10_000;
        tokensOut = _buyQuote(c, amount - fee);
    }

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 out, uint256 fee) {
        Curve storage c = curves[token];
        if (c.city == address(0)) revert UnknownToken(token);
        uint256 gross = _sellQuote(c, tokensIn);
        fee = gross * services[c.city][LAUNCHPAD].feeBps / 10_000;
        out = gross - fee;
    }

    /// @notice Price of one whole token (1e18 units) in asset base units, at the current point of the curve.
    function price(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        if (c.city == address(0)) revert UnknownToken(token);
        return Math.mulDiv(virtualReserve + c.reserve, 1e18, c.tokens);
    }

    function tokensOf(address city) external view returns (address[] memory) {
        return _tokens[city];
    }

    function _buy(address token, uint256 amount, uint256 minTokens) internal returns (uint256 tokensOut) {
        Curve storage c = curves[token];
        if (c.city == address(0)) revert UnknownToken(token);
        if (amount == 0) revert ZeroAmount();
        uint256 fee = amount * services[c.city][LAUNCHPAD].feeBps / 10_000;
        uint256 net = amount - fee;
        tokensOut = _buyQuote(c, net);
        if (tokensOut < minTokens || tokensOut == 0) revert Slippage(tokensOut, minTokens);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        c.reserve += net;
        c.tokens -= tokensOut;
        if (fee > 0) _payCity(c.city, fee);
        IERC20(token).safeTransfer(msg.sender, tokensOut);
        _record(c.city, LAUNCHPAD, amount, fee);
        emit Traded(c.city, token, msg.sender, true, amount, tokensOut, fee);
    }

    /// @dev Constant product over (virtual + real reserve) x tokens on the curve. Rounding favours the curve, so the
    /// product never decreases and a sale can never pay out more than the real reserve.
    function _buyQuote(Curve storage c, uint256 net) internal view returns (uint256) {
        uint256 x = virtualReserve + c.reserve;
        uint256 k = x * c.tokens;
        return c.tokens - Math.ceilDiv(k, x + net);
    }

    function _sellQuote(Curve storage c, uint256 tokensIn) internal view returns (uint256 gross) {
        uint256 x = virtualReserve + c.reserve;
        uint256 k = x * c.tokens;
        gross = x - Math.ceilDiv(k, c.tokens + tokensIn);
        if (gross > c.reserve) gross = c.reserve;
    }

    // ---------------------------------------------------------------- prediction

    /// @notice Stakes `amount` on "above" or "below". The city's prediction fee is taken from the stake and paid to the
    /// city; the rest goes into the pool of the chosen side.
    function predict(uint256 id, bool above, uint256 amount) external nonReentrant {
        Market storage m = _market(id);
        if (block.timestamp >= m.closesAt || m.outcome != Outcome.Open) revert MarketClosed(id);
        if (amount == 0) revert ZeroAmount();
        uint256 fee = amount * services[m.city][PREDICTION].feeBps / 10_000;
        uint256 net = amount - fee;

        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (above) {
            m.poolAbove += net;
            stakeAbove[id][msg.sender] += net;
        } else {
            m.poolBelow += net;
            stakeBelow[id][msg.sender] += net;
        }
        if (fee > 0) _payCity(m.city, fee);
        _record(m.city, PREDICTION, amount, fee);
        emit Predicted(id, msg.sender, above, amount, fee);
    }

    /// @notice Anyone can resolve a market once `ApyFeed` was updated at or after its measurement time. A market
    /// where one side is empty resolves as void (everyone gets their stake back).
    function resolve(uint256 id) external {
        Market storage m = _market(id);
        if (m.outcome != Outcome.Open) revert AlreadyResolved(id);
        if (block.timestamp < m.resolvesAt) revert MarketNotClosed(id);
        (uint32 apyBps,, uint64 updatedAt) = feed.latest(m.sourceId);
        if (updatedAt < m.resolvesAt) revert NoObservationAfterClose(id);
        m.resolvedApyBps = apyBps;
        if (m.poolAbove == 0 || m.poolBelow == 0) m.outcome = Outcome.Void;
        else m.outcome = apyBps > m.thresholdBps ? Outcome.Above : Outcome.Below;
        emit MarketResolved(id, uint8(m.outcome), apyBps);
    }

    /// @notice Voids a market whose feed went silent: possible `VOID_AFTER` past the measurement time if still
    /// unresolved.
    function voidMarket(uint256 id) external {
        Market storage m = _market(id);
        if (m.outcome != Outcome.Open) revert AlreadyResolved(id);
        if (block.timestamp < m.resolvesAt + VOID_AFTER) revert TooEarlyToVoid(id);
        m.outcome = Outcome.Void;
        emit MarketResolved(id, uint8(Outcome.Void), 0);
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        if (amount == 0) revert NothingToClaim(id);
        claimed[id][msg.sender] = true;
        asset.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    function claimable(uint256 id, address user) public view returns (uint256) {
        Market storage m = _market(id);
        if (claimed[id][user] || m.outcome == Outcome.Open) return 0;
        uint256 a = stakeAbove[id][user];
        uint256 b = stakeBelow[id][user];
        if (m.outcome == Outcome.Void) return a + b;
        uint256 total = m.poolAbove + m.poolBelow;
        if (m.outcome == Outcome.Above) return a == 0 ? 0 : Math.mulDiv(a, total, m.poolAbove);
        return b == 0 ? 0 : Math.mulDiv(b, total, m.poolBelow);
    }

    function market(uint256 id) external view returns (Market memory) {
        return _market(id);
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function marketsOf(address city) external view returns (uint256[] memory) {
        return _cityMarkets[city];
    }

    // ---------------------------------------------------------------- internal

    function _onlyMayor(address city) internal view {
        if (!factory.isCity(city)) revert NotCity(city);
        if (msg.sender != ICityVault(city).mayor()) revert NotMayor();
    }

    function _market(uint256 id) internal view returns (Market storage) {
        if (id >= _markets.length) revert UnknownMarket(id);
        return _markets[id];
    }

    // ---------------------------------------------------------------- fee stream

    /// @notice Streams the part of a city's pending fees that is due into its vault. Anyone may call it; every service
    /// use of the city calls it too.
    function release(address city) external nonReentrant returns (uint256) {
        return _release(city);
    }

    /// @notice Fees of `city` that are already due but not yet streamed, plus the rest still pending.
    function releasable(address city) public view returns (uint256 due, uint256 pending) {
        Drip storage d = drips[city];
        pending = d.pending;
        if (pending == 0 || IERC20(city).totalSupply() == 0) return (0, pending);
        uint256 elapsed = block.timestamp - d.last;
        due = elapsed >= dripPeriod ? pending : pending * elapsed / dripPeriod;
    }

    /// @dev The fee reaches residents through the share price once streamed. While a city has no shares (no
    /// residents), its fees wait here; they never go to the mayor directly.
    function _payCity(address city, uint256 fee) internal {
        _release(city);
        drips[city].pending += uint128(fee);
    }

    function _release(address city) internal returns (uint256 due) {
        (due,) = releasable(city);
        Drip storage d = drips[city];
        d.last = uint64(block.timestamp);
        if (due == 0) return 0;
        d.pending -= uint128(due);
        asset.safeTransfer(city, due);
        emit FeesReleased(city, due);
    }

    function _record(address city, uint8 kind, uint256 volume, uint256 fee) internal {
        Stats storage s = stats[city][kind];
        s.volume += uint128(volume);
        s.fees += uint128(fee);
        s.uses += 1;
        emit ServiceUsed(city, kind, msg.sender, volume, fee);
    }
}
