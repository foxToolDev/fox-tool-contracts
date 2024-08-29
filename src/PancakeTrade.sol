// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakeRouter01 {
    function factory() external pure returns (address);

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function factory() external view returns (address);
}

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IPancakeV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}

contract ExecutorBot {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function execute(address target, bytes calldata data, uint256 value) public payable returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        return Address.functionCallWithValue(target, data, value);
    }
}

contract PancakeTrade is Ownable, Multicall, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant _TYPEHASH = keccak256("ParamsHash(uint8 actionType,bytes32 hash)");

    address public immutable factory;
    address public immutable router;
    address public immutable factory3;
    address public immutable routerv3;
    address public immutable executorBotImpl;

    //treasury=>manager
    mapping(address => address) public manager;
    //treasury=>marker
    mapping(address => address) public marker;
    mapping(address => uint256) public markerNonce;
    mapping(address => uint256) public treasuryFee;

    //treasury=>pair=>boolean
    mapping(address => mapping(address => bool)) public pairWL;
    //treasury=>pair=>maxPrice
    mapping(address => mapping(address => uint256)) public priceLimitMax;
    //treasury=>pair=>minPrice
    mapping(address => mapping(address => uint256)) public priceLimitMin;
    //treasury=>gasPrice
    mapping(address => uint256) public gasPriceLimit;

    //fee info
    uint256 public baseFee = 50000;
    uint256 public monthFee;
    uint256 public feeRate; // 10000
    address public feeReceiver;
    mapping(address => mapping(uint256 => uint256)) public curMonthFee;

    modifier onlyTreasuryOrManager(address _treasury) {
        require(msg.sender == manager[_treasury] || msg.sender == _treasury, "t m err");
        _;
    }

    constructor(address _router, address _routerv3) Ownable(msg.sender) EIP712("foxtool", "1") {
        router = _router;
        routerv3 = _routerv3;
        factory = IPancakeRouter01(_router).factory();
        factory3 = ISwapRouter(_routerv3).factory();
        executorBotImpl = address(new ExecutorBot(address(this)));
    }

    function swapExactTokensForTokensFromTreasury(
        address _treasury,
        uint256 deadline,
        address[] memory path,
        uint16 botId,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isFee,
        bytes memory signature
    )
        public
        handleFee(_treasury)
        checkMakerDeadline(
            deadline,
            signature,
            _treasury,
            msg.sender,
            uint8(0),
            keccak256(abi.encodePacked(deadline, path, botId, amountIn, amountOutMin, isFee, msg.sender))
        )
        nonReentrant
    {
        address pair = IPancakeFactory(factory).getPair(path[0], path[1]);
        require(pairWL[_treasury][pair], "pair wl err");
        IERC20(path[0]).safeTransferFrom(_treasury, pair, amountIn);
        address _bot = getBotAddr(_treasury, botId);
        _internalSwap(isFee, amountIn, path, _bot, pair, amountOutMin);
        checkPriceLimit(true, _treasury, pair);
    }

    //v2
    function swapExactTokensForTokensFromBots(
        address _treasury,
        uint256 deadline,
        address[] memory path,
        uint16[] memory botIds,
        uint256[] memory amountIns,
        uint256 amountOutMin,
        bool isFee,
        bytes memory signature
    )
        public
        handleFee(_treasury)
        checkMakerDeadline(
            deadline,
            signature,
            _treasury,
            msg.sender,
            uint8(1),
            keccak256(abi.encodePacked(deadline, path, botIds, amountIns, amountOutMin, isFee, msg.sender))
        )
        nonReentrant
    {
        address pair = IPancakeFactory(factory).getPair(path[0], path[1]);
        require(pairWL[_treasury][pair], "pair wl err");
        uint256 _amountIn = 0;
        for (uint256 i = 0; i < amountIns.length; i++) {
            address _bot = createOrGetBot(_treasury, botIds[i]);
            botApprove(_bot, path[0], address(this), amountIns[i]);
            IERC20(path[0]).safeTransferFrom(_bot, pair, amountIns[i]);
            _amountIn += amountIns[i];
        }
        _internalSwap(isFee, _amountIn, path, _treasury, pair, amountOutMin);
        checkPriceLimit(true, _treasury, pair);
    }

    function _internalSwap(
        bool isFee,
        uint256 _amountIn,
        address[] memory path,
        address to,
        address pair,
        uint256 amountOutMin
    ) private {
        uint256 out;
        if (isFee) {
            out = _swapSupportingFeeOnTransferTokens(path, to, pair);
        } else {
            out = _swap(_amountIn, path, to, pair);
        }
        require(out >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint256 _amountIn, address[] memory path, address to, address pair)
        private
        returns (uint256 amountOut)
    {
        uint256[] memory amounts = IPancakeRouter01(router).getAmountsOut(_amountIn, path);
        (address input, address output) = (path[0], path[1]);
        (address token0,) = sortTokens(input, output);
        amountOut = amounts[1];
        (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IPancakePair(pair).swap(amount0Out, amount1Out, to, new bytes(0));
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address to, address _pair)
        private
        returns (uint256 amountOut)
    {
        uint256 balanceBefore = IERC20(path[1]).balanceOf(to);
        (address input, address output) = (path[0], path[1]);
        (address token0,) = sortTokens(input, output);
        IPancakePair pair = IPancakePair(_pair);
        uint256 amountInput;
        uint256 amountOutput;
        {
            // scope to avoid stack too deep errors
            (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
            (uint256 reserveInput, uint256 reserveOutput) =
                input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
            amountOutput = IPancakeRouter01(router).getAmountOut(amountInput, reserveInput, reserveOutput);
        }
        (uint256 amount0Out, uint256 amount1Out) =
            input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
        pair.swap(amount0Out, amount1Out, to, new bytes(0));
        amountOut = IERC20(path[1]).balanceOf(to) - balanceBefore;
    }

    //v3
    function swapExactTokensForTokensFromTreasuryV3(
        address _treasury,
        uint16 botId,
        bytes memory signature,
        ISwapRouter.ExactInputSingleParams calldata params
    )
        public
        handleFee(_treasury)
        checkMakerDeadline(
            params.deadline,
            signature,
            _treasury,
            msg.sender,
            uint8(2),
            keccak256(
                abi.encodePacked(
                    botId,
                    params.tokenIn,
                    params.tokenOut,
                    params.fee,
                    params.recipient,
                    params.deadline,
                    params.amountIn,
                    params.amountOutMinimum,
                    params.sqrtPriceLimitX96,
                    msg.sender
                )
            )
        )
        nonReentrant
    {
        address pool = getPancakeV3Pool(params.tokenIn, params.tokenOut, params.fee);
        require(pairWL[_treasury][pool], "pool wl err");
        address _bot = createOrGetBot(_treasury, botId);
        IERC20(params.tokenIn).safeTransferFrom(_treasury, _bot, params.amountIn);
        _internalSwapV3(_bot, params);
        checkPriceLimit(false, _treasury, pool);
    }

    function swapExactTokensForTokensFromBotsV3(
        address _treasury,
        uint16[] memory botIds,
        uint256[] memory amountIns,
        bytes memory signature,
        ISwapRouter.ExactInputSingleParams calldata params
    )
        public
        handleFee(_treasury)
        checkMakerDeadline(
            params.deadline,
            signature,
            _treasury,
            msg.sender,
            uint8(3),
            keccak256(
                abi.encodePacked(
                    botIds,
                    amountIns,
                    params.tokenIn,
                    params.tokenOut,
                    params.fee,
                    params.recipient,
                    params.deadline,
                    params.amountIn,
                    params.amountOutMinimum,
                    params.sqrtPriceLimitX96,
                    msg.sender
                )
            )
        )
        nonReentrant
    {
        address pool = getPancakeV3Pool(params.tokenIn, params.tokenOut, params.fee);
        require(pairWL[_treasury][pool], "pool wl err");
        address senderBot = createOrGetBot(_treasury, botIds[0]);
        uint256 amountIn = amountIns[0];
        for (uint256 i = 1; i < botIds.length; i++) {
            address _bot = getBotAddr(_treasury, botIds[i]);
            botTransfer(_bot, params.tokenIn, senderBot, amountIns[i]);
            amountIn += amountIns[i];
        }
        require(amountIn == params.amountIn, "ai err");
        require(_treasury == params.recipient, "rec err");
        _internalSwapV3(senderBot, params);
        checkPriceLimit(false, _treasury, pool);
    }

    function _internalSwapV3(address senderBot, ISwapRouter.ExactInputSingleParams calldata params) private {
        botApprove(senderBot, params.tokenIn, routerv3, params.amountIn);
        bytes memory data = abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, params);
        ExecutorBot(senderBot).execute(routerv3, data, 0);
    }

    function getPancakeV3Pool(address tokenA, address tokenB, uint24 fee) public view returns (address pool) {
        return IPancakeV3Factory(factory3).getPool(tokenA, tokenB, fee);
    }

    modifier checkMakerDeadline(
        uint256 deadline,
        bytes memory signature,
        address _treasury,
        address sender,
        uint8 actionType,
        bytes32 paramsHash
    ) {
        require(!isContract(sender), "con err");
        address _marker = marker[_treasury];
        require(deadline >= block.timestamp, "Router: EXPIRED");
        require(deadline > markerNonce[_marker], "nonce used");
        bytes memory abiEncode = abi.encode(_TYPEHASH, actionType, paramsHash);
        bytes32 digest = _hashTypedDataV4(keccak256(abiEncode));
        require(ECDSA.recover(digest, signature) == _marker, "sig err");
        markerNonce[_marker] = deadline;
        _;
    }

    modifier handleFee(address _treasury) {
        uint256 gas1 = gasleft();
        require(tx.gasprice <= gasPriceLimit[_treasury], "gasprice err");
        _;
        //handle sender fee and dao fee
        uint256 gas2 = gasleft();
        uint256 feeToSender = (gas1 - gas2 + baseFee) * tx.gasprice;
        uint256 total = feeToSender;
        uint256 curMonth = block.timestamp / 30 days;
        if (curMonthFee[_treasury][curMonth] < monthFee && feeRate > 0) {
            feeToSender += 10000;
            uint256 feeToDao = feeRate * feeToSender / 10000;
            curMonthFee[_treasury][curMonth] += feeToDao;
            total = feeToSender + feeToDao;
            Address.sendValue(payable(feeReceiver), feeToDao);
        }
        treasuryFee[_treasury] -= total;
        Address.sendValue(payable(msg.sender), feeToSender);
    }

    function checkPriceLimit(bool isV2, address _treasury, address pair) public view {
        uint256 curPrice;
        uint256 min = priceLimitMin[_treasury][pair];
        uint256 max = priceLimitMax[_treasury][pair];
        if (min == 0 && max == 0) {
            return;
        }
        if (isV2) {
            (uint112 reserve0, uint112 reserve1,) = IPancakePair(pair).getReserves();
            curPrice = 1e18 * uint256(reserve0) / uint256(reserve1);
        } else {
            (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pair).slot0();
            curPrice = uint256(sqrtPriceX96);
        }
        if (min > 0) {
            require(curPrice >= min, "price min limit");
        }
        if (max > 0) {
            require(curPrice <= max, "price max limit");
        }
    }

    function checkZeroAddr(address addr) public view {
        require(addr != address(0), "zero addr");
    }

    function getBotInfo(address _treasury, uint16 startIndex, uint16 endIndex, address token)
        external
        view
        returns (uint256[] memory bals)
    {
        uint256 size = endIndex - startIndex;
        bals = new uint256[](size);
        for (uint16 i = startIndex; i < endIndex; i++) {
            address bot = getBotAddr(_treasury, i);
            if (token != address(0)) {
                bals[i - startIndex] = IERC20(token).balanceOf(bot);
            }
        }
    }

    function botApprove(address _bot, address _token, address _spender, uint256 amount) private {
        uint256 _allowance = IERC20(_token).allowance(_bot, _spender);
        if (_allowance < amount) {
            bytes memory data = abi.encodeWithSelector(IERC20.approve.selector, _spender, type(uint256).max);
            ExecutorBot(_bot).execute(_token, data, 0);
        }
    }

    function botTransfer(address _bot, address _token, address to, uint256 amount) private {
        bytes memory transferData = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        bytes memory returndata = ExecutorBot(_bot).execute(_token, transferData, 0);
        if (returndata.length != 0 && !abi.decode(returndata, (bool))) {
            revert SafeERC20.SafeERC20FailedOperation(_token);
        }
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        amounts = IPancakeRouter01(router).getAmountsOut(amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        amounts = IPancakeRouter01(router).getAmountsIn(amountOut, path);
    }

    receive() external payable {
        treasuryFee[msg.sender] += msg.value;
    }

    // collect token
    function collect(address _treasury, uint16[] memory botIds, address _token)
        external
        onlyTreasuryOrManager(_treasury)
    {
        for (uint256 i = 0; i < botIds.length; i++) {
            address _bot = createOrGetBot(_treasury, botIds[i]);
            botTransfer(_bot, _token, _treasury, IERC20(_token).balanceOf(_bot));
        }
    }

    function createOrGetBot(address _treasury, uint16 botId) public returns (address _bot) {
        require(botId < 2 ** 12, "bot id err");
        _bot = getBotAddr(_treasury, botId);
        if (!isContract(_bot)) {
            Clones.cloneDeterministic(executorBotImpl, bytes32(uint256(uint160(_treasury)) << 12 | botId));
        }
    }

    function getBotAddr(address _treasury, uint16 botId) public view returns (address) {
        require(botId < 2 ** 12, "bot id err");
        return Clones.predictDeterministicAddress(
            executorBotImpl, bytes32(uint256(uint160(_treasury)) << 12 | botId), address(this)
        );
    }

    function getBotAddrs(address _treasury, uint16 start, uint16 end) public view returns (address[] memory bots) {
        require(start < 2 ** 12, "start err");
        require(end < 2 ** 12, "end err");
        bots = new address[](end - start + 1);
        for (uint16 botId = start; botId <= end; botId++) {
            bots[botId - start] = Clones.predictDeterministicAddress(
                executorBotImpl, bytes32(uint256(uint160(_treasury)) << 12 | botId), address(this)
            );
        }
    }

    function getPair(address token0, address token1) public view returns (address pair) {
        pair = IPancakeFactory(factory).getPair(token0, token1);
    }

    function isContract(address account) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    //set manager by treasury
    function setManager(address _manager) external {
        checkZeroAddr(_manager);
        manager[msg.sender] = _manager;
    }

    //set pair by treasury
    function setPair(address pair, bool wl) external {
        checkZeroAddr(pair);
        pairWL[msg.sender][pair] = wl;
    }

    //set maker by manager or treasury
    function setMaker(address _treasury, address maker) external onlyTreasuryOrManager(_treasury) {
        marker[_treasury] = maker;
    }

    //set price limit by manager or treasury
    function setPriceLimit(address _treasury, address _pair, uint256 _minPrice, uint256 _maxPrice)
        external
        onlyTreasuryOrManager(_treasury)
    {
        priceLimitMin[_treasury][_pair] = _minPrice;
        priceLimitMax[_treasury][_pair] = _maxPrice;
    }

    //set gas price limit by manager or treasury
    function setGasPriceLimit(address _treasury, uint256 _gasPrice) external onlyTreasuryOrManager(_treasury) {
        gasPriceLimit[_treasury] = _gasPrice;
    }

    //withdraw fee
    function withdrawFee(address _treasury) external onlyTreasuryOrManager(_treasury) {
        uint256 val = treasuryFee[_treasury];
        require(val > 0, "valf err");
        treasuryFee[_treasury] = 0;
        payable(msg.sender).transfer(val);
    }

    function depositFee(address _treasury) public payable {
        require(msg.value > 0, "val err");
        checkZeroAddr(_treasury);
        treasuryFee[_treasury] += msg.value;
    }

    function depositDaoFee(address _treasury) public payable {
        checkZeroAddr(_treasury);
        checkZeroAddr(feeReceiver);
        require(msg.value > 0, "val err");
        uint256 curMonth = block.timestamp / 30 days;
        curMonthFee[_treasury][curMonth] += msg.value;
        Address.sendValue(payable(feeReceiver), msg.value);
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "PancakeLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "PancakeLibrary: ZERO_ADDRESS");
    }

    //manager
    function setFee(uint256 _monthFee, uint256 _feeRate, address _feeReceiver) external onlyOwner {
        require(_feeRate < 10000, "fr err");
        checkZeroAddr(_feeReceiver);
        monthFee = _monthFee;
        feeRate = _feeRate;
        feeReceiver = _feeReceiver;
    }

    //manager
    function setBaseFee(uint256 _baseFee) external onlyOwner {
        baseFee = _baseFee;
    }

    // transfer utils
    // batch transfer eth
    function batchTransferEth(address[] memory addrs, uint256 amount) external payable {
        require(msg.value == amount * addrs.length, "bte");
        for (uint256 i = 0; i < addrs.length; i++) {
            checkZeroAddr(addrs[i]);
            Address.sendValue(payable(addrs[i]), amount);
        }
    }

    // batch transfer token
    function batchTransferToken(address[] memory addrs, uint256 amount, address token) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            checkZeroAddr(addrs[i]);
            IERC20(token).safeTransferFrom(msg.sender, addrs[i], amount);
        }
    }
}
