
// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/GSN/Context.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";
import "https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router01.sol";
import "https://github.com/KL5616/test_contracts/blob/main/Balancer.sol";
import "https://github.com/KL5616/test_contracts/blob/main/Swapper.sol";
import "https://github.com/KL5616/test_contracts/blob/main/RewardWallet.sol";

contract FRACTAL3 is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    IUniswapV2Router02 public immutable _uniswapV2Router;

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    mapping (address => bool) private _isExcluded;
    address[] private _excluded;
    address public _rewardWallet;
    uint256 public _initialRewardLockAmount;
    address public _uniswapETHPool;

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 10000000e9;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 public _tFeeTotal;
    uint256 public _tBurnTotal;

    string private _name = 'FractalDefi.com';
    string private _symbol = 'FRCTL';
    uint8 private _decimals = 9;

    uint256 public _feeDecimals = 1;
    uint256 public _maxTxAmount = 2000000e9;
    uint256 public _minTokensBeforeSwap = 10000e9;
    uint256 public _minInterestForReward = 15e9;  // 1.5% interest
    uint256 private _autoSwapCallerFee = 200e9;

    bool private inSwapAndLiquify;
    bool public swapAndLiquifyEnabled;
    bool public tradingEnabled;
    bool private _isCycling;

    address private currentPairTokenAddress;
    address private currentPoolAddress;

    uint256 private _liquidityRemoveFee = 2;
    uint256 private _fractalizeCallerFee = 5;
    uint256 private _minTokenForFractalize = 1000e9;
    uint256 private _lastFractalize;
    uint256 private _fractalizeInterval = 1 hours;

    uint256 private _taxFeeDefault; // 1%
    uint256 private _lockFeeDefault; // 1%
    uint256 private _burnFeeDefault;
    uint256 private _devFeeDefault;
    uint256 private _cycleLimit;
    uint256 private _MAX_TAX_LIMIT; // 20%;
    uint256 private _feeInterval; // we reset the interval at 4 turns
    uint256 private _timeSinceLastFeeUpdate;
    uint256 private _timeCheckInterval;
    uint256 private _taxFee;
    uint256 private _lockFee;
    uint256 private _burnFee;
    uint256 private _devFee;
    // pre-set to true, so when iscycled is toggled we don't have to flip 4 switches
    bool public taxFeeIsCycling = true;
    bool public burnFeeIsCycling = true;
    bool public devFeeIsCycling = true;
    bool public lockFeeIsCycling = true;

    bool public _isBotThrottling;
    uint256 public _txCounter;
    uint256 public _txLimit;
    uint256 public buyLimit;

    address public devAddr;

    event DefaultFeesUpdated(uint256 cycleLimit, uint256 taxFDefault, uint256 burnFDefault, uint256 devFDefault, uint256 lockFDefault );
    event FeeDecimalsUpdated(uint256 taxFeeDecimals);
    event MaxTxAmountUpdated(uint256 maxTxAmount);
    event WhitelistUpdated(address indexed pairTokenAddress);
    event TradingEnabled();
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        address indexed pairTokenAddress,
        uint256 tokensSwapped,
        uint256 pairTokenReceived,
        uint256 tokensIntoLiqudity
    );
    event Rebalance(uint256 tokenBurnt);
    event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
    event AutoSwapCallerFeeUpdated(uint256 autoSwapCallerFee);
    event MinInterestForRewardUpdated(uint256 minInterestForReward);
    event LiquidityRemoveFeeUpdated(uint256 liquidityRemoveFee);
    event FractalizeCallerFeeUpdated(uint256 rebalanceCallerFee);
    event MinTokenForFractalizeUpdated(uint256 minRebalanceAmount);
    event FractalizeIntervalUpdated(uint256 rebalanceInterval);
    event Redistributed(address from, uint256 t, uint256 rAmount, uint256 tAmount);
    event BotThrottlerUpdated(bool to);


    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    Balancer public balancer;
    Swapper public swapper;

    //0xf164fC0Ec4E93095b804a4795bBe1e041497b92a  1000000000000000 -> 10% to rewards
    constructor (IUniswapV2Router02 uniswapV2Router, uint256 initialRewardLockAmount, address dev) public {
        _lastFractalize = block.timestamp;
        devAddr = dev;

        _uniswapV2Router = uniswapV2Router;
        _rewardWallet = address(new RewardWallet());
        _initialRewardLockAmount = initialRewardLockAmount;

        balancer = new Balancer(this, uniswapV2Router);
        swapper = new Swapper(this, uniswapV2Router);

        currentPoolAddress = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        currentPairTokenAddress = uniswapV2Router.WETH();
        _uniswapETHPool = currentPoolAddress;

        updateSwapAndLiquifyEnabled(false);

        _rOwned[_msgSender()] = reflectionFromToken(_tTotal.sub(_initialRewardLockAmount), false);
        _rOwned[_rewardWallet] = reflectionFromToken(_initialRewardLockAmount, false);

        _isCycling = false;
        _taxFeeDefault = 10;
        _burnFeeDefault = 5;
        _devFeeDefault = 5;
        _lockFeeDefault = 20;
        _cycleLimit = 4;
        _MAX_TAX_LIMIT = 200; // 20%;
        _feeInterval = 0; // we reset the interval at 4 turns
        _timeSinceLastFeeUpdate = block.timestamp;
        _timeCheckInterval = 3600;
        _lockFee = _lockFeeDefault;
        _taxFee = _taxFeeDefault;
        _burnFee = _burnFeeDefault;
        _devFee = _devFeeDefault;
        _severePunishment = true;
        _frontRunGuard = true;
        _isBotThrottling = false;
        _goEasyOnThem = false;
        _txLimit = 200;
        buyLimit = 10000; // 10000 $FRCTL

        emit Transfer(address(0), _msgSender(), _tTotal.sub(_initialRewardLockAmount));
        emit Transfer(address(0), _rewardWallet, _initialRewardLockAmount);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcluded[account];
    }


    function reflect(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");
        (uint256 rAmount,,,,,,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns (uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function excludeAccount(address account) public onlyOwner() {
        require(account != 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, 'We can not exclude Uniswap router.');
        require(account != address(this), 'We can not exclude contract self.');
        require(account != _rewardWallet, 'We can not exclude reweard wallet.');
        require(!_isExcluded[account], "Account is already excluded");

        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeAccount(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already included");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // ANTI BOT MEASURES //
    mapping(address => uint256) private _lastTransferred;
    mapping(address => uint256) private _possibleFrontRunners;
    event PunishedBot(address bot);
    event FrontRunnerStrike(address possibleBot, uint256 count);
    bool public _severePunishment;
    bool public _frontRunGuard;
    bool public _lastlastTransferWasABuy;
    address private _lastTransfer;
    address private _lastlastTransfer;
    uint256 private _lastBlockNumber;
    bool private _goEasyOnThem;

    function _toggleGoEasyOnThem() external onlyOwner{
        _goEasyOnThem = !_goEasyOnThem;
    }

    function _toggleFrontRunGuard() external onlyOwner{
        _frontRunGuard = !_frontRunGuard;
    }

    function _toggleSeverePunishment() external onlyOwner{
        _severePunishment = !_severePunishment;
    }

    function setBuySizeLimit(uint256 limit) external onlyOwner {
        buyLimit = limit;
    }

    function toggleBotThrottling() external onlyOwner {
        if(_isBotThrottling) {
            _txCounter = 0; // reset tx counter back to 0 if bots are being a pain
        }
        _isBotThrottling = !_isBotThrottling;
        emit BotThrottlerUpdated(_isBotThrottling);

    }

    // how long we keep the buy limit going
    function setNthTxLimit(uint256 txLimit) external onlyOwner {
        _txLimit = txLimit;
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "ERC20: Transfer amount must be greater than zero");

        // short-circuit if we are not cycling
        if(_isCycling && block.timestamp > (_timeSinceLastFeeUpdate.add(_timeCheckInterval))) {
            _cycleFees();
        }

        if(sender != owner() && recipient != owner() && !inSwapAndLiquify) {
            require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
            if((_msgSender() == currentPoolAddress || _msgSender() == address(_uniswapV2Router)) && !tradingEnabled)
                require(false, "Trading is disabled.");
        }


        if(!inSwapAndLiquify) {
            uint256 lockedBalanceForPool = balanceOf(address(this));
            bool overMinTokenBalance = lockedBalanceForPool >= _minTokensBeforeSwap;
            if (
                overMinTokenBalance &&
                msg.sender != currentPoolAddress &&
                swapAndLiquifyEnabled
            ) {
                if(currentPairTokenAddress == _uniswapV2Router.WETH())
                    swapAndLiquifyForEth(lockedBalanceForPool);
                else
                    swapAndLiquifyForTokens(currentPairTokenAddress, lockedBalanceForPool);
            }
        }
         // not a good use of gas but we need to keep these in scope
        bool isBeingPunished = false;
        uint256  tf = _taxFee;
        uint256  df = _devFee;
        uint256  lf = _lockFee;
        // since we are bootstrapping liquidity, we want to protect holders from bots and someone snatching up all the tokens
        // also, fuck bots.
        if(_isBotThrottling) {
            // if there is a tx limit then we assume the bot will turn off afterwards.
                if(_txCounter < _txLimit){
                    // we can also set the buys to 0
                    // if txCounter is less than y make sure buy limits are enforced, else time to turn off bot throttling
                    // if this contract is not being sold to
                    if(recipient != address(this)){
                        require(_lastTransfer != tx.origin && _lastBlockNumber != block.number, "THROTTLEBOT: Are you a spam bot?");
                    }
                    require(amount <= (buyLimit * 10 ** _decimals), "THROTTLEBOT: Exceeded buy limit before txLimit");
                    _txCounter++;
                } else {
                    _isBotThrottling = !_isBotThrottling;
                    emit BotThrottlerUpdated(_isBotThrottling);
                }
                  _lastBlockNumber = block.number;
        }

        if(_frontRunGuard && _lastlastTransfer == tx.origin){
            bool wasFrontRunAttempt = _lastlastTransferWasABuy == (recipient == address(this));
            if(wasFrontRunAttempt){
                if(_goEasyOnThem){
                    require(!wasFrontRunAttempt, "GUARDBOT says: no");
                }
                _possibleFrontRunners[tx.origin] += 1;
                emit FrontRunnerStrike(tx.origin, _possibleFrontRunners[tx.origin]);
            }
            // timesPossiblyFrontRunning, 3 strikes rule
            if(_possibleFrontRunners[tx.origin] > 3) {
                isBeingPunished = true;
                if(_severePunishment){
                    _taxFee = _taxFeeDefault.mul(_feeInterval).add(30);
                    _devFee = _devFeeDefault.mul(_feeInterval).add(30);
                    _lockFee = _lockFeeDefault.mul(_feeInterval).add(30);
                }
            }
        }


        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }

        // save gas on assignments
        if(_frontRunGuard){
            _lastTransferred[tx.origin] = block.timestamp;
            _lastlastTransfer = _lastTransfer; // used to prevent front-running bots
            _lastlastTransferWasABuy = recipient != address(this);
            _lastTransfer = tx.origin;
            if(isBeingPunished){
                if(_severePunishment){
                    _taxFee = tf;
                    _devFee = df;
                    _lockFee = lf;
                }
                emit PunishedBot(tx.origin); // we can always use this to exclude later
            }
        }
        // cleanup
        delete isBeingPunished;
        delete df;
        delete tf;
        delete lf;
    }

    receive() external payable {}

    function swapAndLiquifyForEth(uint256 lockedBalanceForPool) private lockTheSwap {
        // split the contract balance except swapCallerFee into halves
        uint256 lockedForSwap = lockedBalanceForPool.sub(_autoSwapCallerFee);
        uint256 half = lockedForSwap.div(2);
        uint256 otherHalf = lockedForSwap.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half);

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidityForEth(otherHalf, newBalance);

        emit SwapAndLiquify(_uniswapV2Router.WETH(), half, newBalance, otherHalf);

        _transfer(address(this), msg.sender, _autoSwapCallerFee);

        _sendRewardInterestToPool();
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _uniswapV2Router.WETH();

        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // make the swap
        _uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidityForEth(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );
    }

    function swapAndLiquifyForTokens(address pairTokenAddress, uint256 lockedBalanceForPool) private lockTheSwap {
        // split the contract balance except swapCallerFee into halves
        uint256 lockedForSwap = lockedBalanceForPool.sub(_autoSwapCallerFee);
        uint256 half = lockedForSwap.div(2);
        uint256 otherHalf = lockedForSwap.sub(half);

        _transfer(address(this), address(swapper), half);

        uint256 initialPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this));

        // swap tokens for pairToken
        swapper.swapTokens(pairTokenAddress, half);

        uint256 newPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this)).sub(initialPairTokenBalance);

        // add liquidity to uniswap
        addLiquidityForTokens(pairTokenAddress, otherHalf, newPairTokenBalance);

        emit SwapAndLiquify(pairTokenAddress, half, newPairTokenBalance, otherHalf);

        _transfer(address(this), msg.sender, _autoSwapCallerFee);

        _sendRewardInterestToPool();
    }

    function addLiquidityForTokens(address pairTokenAddress, uint256 tokenAmount, uint256 pairTokenAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);
        IERC20(pairTokenAddress).approve(address(_uniswapV2Router), pairTokenAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidity(
            address(this),
            pairTokenAddress,
            tokenAmount,
            pairTokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );
    }

    function fractalize() public lockTheSwap {
        require(balanceOf(_msgSender()) >= _minTokenForFractalize, "Need MOAR FRACTALs");
        require(block.timestamp > _lastFractalize + _fractalizeInterval, 'Chill please. Fractalization. soon.');
        _lastFractalize = block.timestamp;

        uint256 amountToRemove = IERC20(_uniswapETHPool).balanceOf(address(this)).mul(_liquidityRemoveFee).div(100);

        removeLiquidityETH(amountToRemove);
        balancer.rebalance();

        uint256 tNewTokenBalance = balanceOf(address(balancer));
        uint256 tRewardForCaller = tNewTokenBalance.mul(_fractalizeCallerFee).div(100);
        uint256 tBurn = tNewTokenBalance.sub(tRewardForCaller);

        uint256 currentRate =  _getRate();
        uint256 rBurn =  tBurn.mul(currentRate);

        _rOwned[_msgSender()] = _rOwned[_msgSender()].add(tRewardForCaller.mul(currentRate));
        _rOwned[address(balancer)] = 0;

        _tBurnTotal = _tBurnTotal.add(tBurn);
        _tTotal = _tTotal.sub(tBurn);
        _rTotal = _rTotal.sub(rBurn);

        emit Transfer(address(balancer), _msgSender(), tRewardForCaller);
        emit Transfer(address(balancer), address(0), tBurn);
        emit Rebalance(tBurn);
    }

    function removeLiquidityETH(uint256 lpAmount) private returns(uint ETHAmount) {
        IERC20(_uniswapETHPool).approve(address(_uniswapV2Router), lpAmount);
        (ETHAmount) = _uniswapV2Router
            .removeLiquidityETHSupportingFeeOnTransferTokens(
                address(this),
                lpAmount,
                0,
                0,
                address(balancer),
                block.timestamp
            );
    }

    function _sendRewardInterestToPool() private {
        uint256 tRewardInterest = balanceOf(_rewardWallet).sub(_initialRewardLockAmount);
        if(tRewardInterest > _minInterestForReward) {
            uint256 rRewardInterest = reflectionFromToken(tRewardInterest, false);
            _rOwned[currentPoolAddress] = _rOwned[currentPoolAddress].add(rRewardInterest);
            _rOwned[_rewardWallet] = _rOwned[_rewardWallet].sub(rRewardInterest);
            emit Transfer(_rewardWallet, currentPoolAddress, tRewardInterest);
            IUniswapV2Pair(currentPoolAddress).sync();
        }
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock, uint256 tBurn) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            uint256 rBurn = tBurn.mul(currentRate);
            _reflectFee(rFee, rBurn, tFee, tBurn);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
        emit Redistributed(sender, 1, rAmount, tAmount);

    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock, uint256 tBurn) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _tOwned[recipient] = _tOwned[recipient].add(tAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            uint256 rBurn = tBurn.mul(currentRate);
            _reflectFee(rFee, rBurn, tFee, tBurn);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
        emit Redistributed(sender, 2, rAmount, tAmount);

    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock, uint256 tBurn) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            uint256 rBurn = tBurn.mul(currentRate);
            _reflectFee(rFee, rBurn, tFee, tBurn);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
        emit Redistributed(sender, 3, rAmount, tAmount);

    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock, uint256 tBurn) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _tOwned[recipient] = _tOwned[recipient].add(tAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        }
        else {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            uint256 rBurn = tBurn.mul(currentRate);
            _reflectFee(rFee, rBurn, tFee, tBurn);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
        emit Redistributed(sender, 4, rAmount, tAmount);

    }

    function _reflectFee(uint256 rFee, uint256 rBurn, uint256 tFee, uint256 tBurn) private {
        uint256 rDev = rFee.mul(_devFee).div(_taxFee);
        uint256 tDev = tFee.mul(_devFee).div(_taxFee);
        _rOwned[devAddr] = _rOwned[devAddr].add(rDev);
        _rTotal = _rTotal.sub(rFee).sub(rBurn).add(rDev);
        _tFeeTotal = _tFeeTotal.add(tFee).sub(tDev);
        _tBurnTotal = _tBurnTotal.add(tBurn);
        _tTotal = _tTotal.sub(tBurn);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLock, uint256 tBurn) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLock, tBurn);
    }

    function _getTValues(uint256 tAmount) private view returns(uint256, uint256, uint256, uint256) {
        uint256 tFee = tAmount.mul(_taxFee).div(10**(_feeDecimals + 2));
        uint256 tLockFee = tAmount.mul(_lockFee).div(10**(_feeDecimals + 2));
        uint256 tBurn = tAmount.mul(_burnFee).div(10**(_feeDecimals + 2));
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLockFee).sub(tBurn);
        return (tTransferAmount, tFee, tLockFee, tBurn);
    }

    function _getRValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
        (, uint256 tFee, uint256 tLock, uint256 tBurn) = _getTValues(tAmount);
        uint256 currentRate = _getRate();
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(tLock.mul(currentRate)).sub(tBurn.mul(currentRate));
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() public view returns(uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return _rTotal.div(_tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return _rTotal.div(_tTotal);
        return rSupply.div(tSupply);
    }

    // CYCLER

    function _setDefaults() internal {
        _feeInterval = 1; // by the time it gets to 6, itll restart and go back to 1
        _taxFee = _taxFeeDefault;
        _burnFee = _burnFeeDefault;
        _devFee = _devFeeDefault;
        _lockFee = _lockFeeDefault;
    }

    function _toggleIsCycling() external onlyOwner() {
        // whether we turn cycling on or off we make sure we start over
        _isCycling = !_isCycling;
        _setDefaults();
    }

    function _toggleTaxFeeCycling() external onlyOwner(){
        // we only switch this when we are turning it from on to off
        if(taxFeeIsCycling){
            _taxFee = _taxFeeDefault;
        }
         taxFeeIsCycling = !taxFeeIsCycling;
    }
    function _toggleBurnFeeCycling() external onlyOwner(){
        if(burnFeeIsCycling){
            _burnFee = _burnFeeDefault;
        }
         burnFeeIsCycling = !burnFeeIsCycling;
    }
    function _toggleDevFeeCycling() external onlyOwner(){
        if(devFeeIsCycling){
            _devFee = _devFeeDefault;
        }
         devFeeIsCycling = !devFeeIsCycling;
    }
    function _toggleLockFeeCycling() external onlyOwner(){
        if(lockFeeIsCycling){
            _lockFee = _lockFeeDefault;
        }
         lockFeeIsCycling = !lockFeeIsCycling;
    }

    function _cycleFees() internal {
        // we assume that ts is new since this was called
        _timeSinceLastFeeUpdate = block.timestamp;
        // we start over after the interval
        if(_feeInterval > _cycleLimit){
            _setDefaults();
        } else {
            // sanity check
            require(_feeInterval > 0, "feeInterval should not be 0");
            _feeInterval = _feeInterval.add(1);
            if (taxFeeIsCycling){
                _taxFee = _taxFeeDefault.mul(_feeInterval);
            }
            if (burnFeeIsCycling){
                _burnFee = _burnFeeDefault.mul(_feeInterval);
            }
            if (devFeeIsCycling){
                _devFee = _devFeeDefault.mul(_feeInterval);
            }
            if (lockFeeIsCycling){
                _lockFee = _lockFeeDefault.mul(_feeInterval);
            }
        }
    }

    function _getMaxTotalTax(uint256 cl, uint256 td, uint256 bd, uint256 dd, uint256 ld) public pure returns (uint256){
        return cl.mul(td).add(cl.mul(bd)).add(cl.mul(dd)).add(cl.mul(ld));
    }

    function getCurrentCycle() public view returns (uint256){
        return _feeInterval;
    }
    function getCurrentTotalTax() public view returns(uint256){
        return (_taxFee).add(_devFee).add(_lockFee).add(_burnFee);
    }
     function getTaxFee() public view returns(uint256) {
        return _taxFee;
    }
    function getLockFee() public view returns(uint256) {
        return _lockFee;
    }
    function getDevFee() public view returns(uint256) {
        return _devFee;
    }
    function getBurnFee() public view returns(uint256) {
        return _burnFee;
    }
    function getCycleLimit() public view returns(uint256) {
        return _cycleLimit;
    }
    function getIsCycling() public view returns(bool) {
        return _isCycling;
    }
    function getDefaults() public view returns(uint256,uint256,uint256,uint256,uint256,uint256) {
        return (_cycleLimit,_taxFeeDefault, _burnFeeDefault, _devFeeDefault, _lockFeeDefault, _MAX_TAX_LIMIT);
    }

    // to save on gas + contract size we will set all defaults at once
    function setNewDefaults(uint256 cycleLimit, uint256 txfd, uint256 bufd, uint256 defd, uint256 lofd)
    external
    onlyOwner(){
        require(_getMaxTotalTax(cycleLimit, txfd, bufd, defd, lofd) <= _MAX_TAX_LIMIT, "cycledFees > _MAX_TAX_LIMIT");
        require(defd <= _taxFeeDefault, 'devFee > taxFee');
        require(bufd <= _taxFeeDefault, 'burnFee > taxFee');
        require(cycleLimit > 0, "!=0");
        require(txfd > 0 && txfd.mul(cycleLimit) <= _MAX_TAX_LIMIT, 'tax < 0');
        _cycleLimit = cycleLimit;
        _taxFeeDefault = txfd;
        _burnFeeDefault = bufd;
        _devFeeDefault = defd;
        _lockFeeDefault = lofd;
        _setDefaults();
        emit DefaultFeesUpdated(cycleLimit, txfd, bufd, defd, lofd);
    }

    // this sets how often intervals will occur within the specified cycle limit
    // ie. if this is set to 3600, then we will go through the cycle every hour until limit
    function _setTimeCheckInterval(uint256 timeCheckInterval) external onlyOwner() {
        require(timeCheckInterval >= 1, "timeCheckInterval must be greater or equal to 1");
        _timeCheckInterval = timeCheckInterval;
    }

    function setDevAddr(address _devAddr) external {
        require(_msgSender() == devAddr , '!dev');
        devAddr = _devAddr;
    }

    // FRACTALIZER

    function getCurrentPoolAddress() public view returns(address) {
        return currentPoolAddress;
    }
    function getCurrentPairTokenAddress() public view returns(address) {
        return currentPairTokenAddress;
    }
    function getLiquidityRemoveFee() public view returns(uint256) {
        return _liquidityRemoveFee;
    }
    function getFractalizeCallerFee() public view returns(uint256) {
        return _fractalizeCallerFee;
    }
    function getMinTokenForFractalize() public view returns(uint256) {
        return _minTokenForFractalize;
    }
    function getLastFractalize() public view returns(uint256) {
        return _lastFractalize;
    }
    function getFractalizeInterval() public view returns(uint256) {
        return _fractalizeInterval;
    }
    function _setFeeDecimals(uint256 feeDecimals) external onlyOwner() {
        require(feeDecimals >= 0 && feeDecimals <= 2, 'fee decimals should be in 0 - 2');
        _feeDecimals = feeDecimals;
        emit FeeDecimalsUpdated(feeDecimals);
    }
    function _setMaxTxAmount(uint256 maxTxAmount) external onlyOwner() {
        require(maxTxAmount >= 500000e9 , 'maxTxAmount < 500000e9');
        _maxTxAmount = maxTxAmount;
        emit MaxTxAmountUpdated(maxTxAmount);
    }
    function _setMinTokensBeforeSwap(uint256 minTokensBeforeSwap) external onlyOwner() {
        require(minTokensBeforeSwap >= 50e9 && minTokensBeforeSwap <= 25000e9 , 'minTokenBeforeSwap should be in 50e9 - 25000e9');
        require(minTokensBeforeSwap > _autoSwapCallerFee , 'minTokenBeforeSwap < autoSwapCallerFee');
        _minTokensBeforeSwap = minTokensBeforeSwap;
        emit MinTokensBeforeSwapUpdated(minTokensBeforeSwap);
    }

    function _setAutoSwapCallerFee(uint256 autoSwapCallerFee) external onlyOwner() {
        require(autoSwapCallerFee >= 1e9, 'autoSwapCallerFee < 1e9');
        _autoSwapCallerFee = autoSwapCallerFee;
        emit AutoSwapCallerFeeUpdated(autoSwapCallerFee);
    }

    function _setMinInterestForReward(uint256 minInterestForReward) external onlyOwner() {
        _minInterestForReward = minInterestForReward;
        emit MinInterestForRewardUpdated(minInterestForReward);
    }

    function _setLiquidityRemoveFee(uint256 liquidityRemoveFee) external onlyOwner() {
        require(liquidityRemoveFee >= 1 && liquidityRemoveFee <= 10 , 'lf < 1, lf > 15');
        _liquidityRemoveFee = liquidityRemoveFee;
        emit LiquidityRemoveFeeUpdated(liquidityRemoveFee);
    }

    function _setFractalizeCallerFee(uint256 fractalizeCallerFee) external onlyOwner() {
        require(fractalizeCallerFee >= 1 && fractalizeCallerFee <= 15 , 'fc < 1, > 15');
        _fractalizeCallerFee = fractalizeCallerFee;
        emit FractalizeCallerFeeUpdated(fractalizeCallerFee);
    }

    function _setMinTokenForFractalize(uint256 minTokenForFractalize) external onlyOwner() {
        _minTokenForFractalize = minTokenForFractalize;
        emit MinTokenForFractalizeUpdated(minTokenForFractalize);
    }

    function _setFractalizeInterval(uint256 fractalizeInterval) external onlyOwner() {
        _fractalizeInterval = fractalizeInterval;
        emit FractalizeIntervalUpdated(fractalizeInterval);
    }

    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function _updateWhitelist(address poolAddress, address pairTokenAddress) public onlyOwner() {
        require(poolAddress != address(0), "Pool address is zero.");
        require(pairTokenAddress != address(0), "Pair token address is zero.");
        require(pairTokenAddress != address(this), "Pair token address self address.");
        require(pairTokenAddress != currentPairTokenAddress, "Pair token address is same as current one.");

        currentPoolAddress = poolAddress;
        currentPairTokenAddress = pairTokenAddress;

        emit WhitelistUpdated(pairTokenAddress);
    }

    function _enableTrading() external onlyOwner() {
        tradingEnabled = true;
        TradingEnabled();
    }
}
