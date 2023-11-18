// Tg: https://t.me/heppertoken
// website: https://heppertoken.com
//X: @HepperTokeen

// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
}

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IERC20 rewardToken = IERC20(0x55d398326f99059fF775485246999027B3197955); //USDT
    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; //WETH

    IDEXRouter router;

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) public shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;
 
    // minPeriod is the minimum time in seconds between distributions of rewards.
    // The value is set to 720 minutes i.e 5 hours (720 * 60 seconds).
    uint256 public minPeriod = 720 * 60;

    // minDistribution is the minimum amount that can be distributed in a single transaction.
    uint256 public minDistribution = 1000 * 10**9;

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _router) {
        router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        _token = msg.sender;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 balanceBefore = rewardToken.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(rewardToken);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = rewardToken.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            rewardToken.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }
    
    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract Hepper is ERC20Votes, Ownable {
    using SafeMath for uint256;

    address public rewardToken = address(0x55d398326f99059fF775485246999027B3197955); //USDT

    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; //WBNB
    
    address public deadWallet = 0x000000000000000000000000000000000000dEaD;
    address public marketingWallet =  address(0x12289A315719a89B50837426550982A763b9E9B9);

    uint8 constant _decimals = 9;

    uint256 _totalSupply = 1000000 * 10**_decimals;

    uint256 public maxTransactionAmount = (_totalSupply * 4) / 100;
    uint256 public maxWalletSize = (_totalSupply * 8) / 100;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;
    mapping (address => bool) _isLimitExempt;
    mapping (address => bool) isDividendExempt;

    uint256 public marketingFee = 2; 
    uint256 public rewardFee = 3;
    uint256 public liquidityFee = 2;


    uint256 public totalFee = marketingFee + rewardFee + liquidityFee;
    uint256 public feeDenominator  = 100; // Using larger denominator for lower fees

    IDEXRouter public router;
    address public pair;

    DividendDistributor public distributor;
    uint256 distributorGas = 500000;


    bool public isTradeOpen;
    bool public isWhitelistOpen = true;
    bool public isSizeLimitsOpen = true;
    bool public swapEnabled = true;
    uint256 public swapTokensAtAmount = _totalSupply * 1 / 50000;

    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event TransferForeignToken(address token, uint256 amount);

    constructor () ERC20("Hepper Token", "HPT") ERC20Permit("Hepper Token") {
        router = IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E );
        pair = IDEXFactory(router.factory()).createPair(WBNB, address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;

        distributor = new DividendDistributor(address(router));

        address _owner = msg.sender;
       
        isFeeExempt[_owner] = true;
        isTxLimitExempt[_owner] = true;
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[deadWallet] = true;

        _isLimitExempt[owner()] = true;
        _isLimitExempt[deadWallet] = true;
        _isLimitExempt[address(this)] = true;
        _isLimitExempt[marketingWallet] = true;

        _balances[_owner] = _totalSupply;
        emit Transfer(address(0), _owner, _totalSupply);
    }

    receive() external payable { }

    function totalSupply() public view virtual override returns (uint256) { return _totalSupply; }
    function decimals() public view virtual override returns (uint8) { return _decimals; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) public view override  virtual returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }

    function updateSizeLimits(
        uint256 _maxTxnAmount,
        uint256 _maxWalletSize,
        uint256 _percent
    ) external onlyOwner {
        uint256 newMaxTxnAmount = (_totalSupply * _maxTxnAmount) / _percent;
        uint256 newMaxWalletSize = (_totalSupply * _maxWalletSize) / _percent;

        require(
            newMaxTxnAmount >= (_totalSupply * 1) / 100,
            "Value must be greater than 1% of the total supply"
        );
        require(
            newMaxWalletSize >= (_totalSupply * 1) / 100,
            "Value must be greater than 1% of the total supply"
        );

        maxTransactionAmount = newMaxTxnAmount;
        maxWalletSize = newMaxWalletSize;
    }

    function updateSwapTokensAtAmount(
        uint256 _swapAmount,
        uint256 _percent
    ) external onlyOwner {
        swapTokensAtAmount = (_totalSupply * _swapAmount) / _percent;
    }

    function enableTrade() external onlyOwner {
        require(isTradeOpen == false, "Trade is already enabled");
        isTradeOpen = true;
    }

    function closeWhiteListRound() external onlyOwner {
        require(isWhitelistOpen == true, "Whitelist already disabled");
        isWhitelistOpen = false;
    }

    function disableSizeLimits() external onlyOwner {
        require(isSizeLimitsOpen == true, "Size limit already disabled");
        isSizeLimitsOpen = false;
    }


    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {


        if(inSwap){ return _basicTransfer(sender, recipient, amount); }

        require(
            isTradeOpen || isFeeExempt[sender] || isFeeExempt[recipient],
            "Hepper Token is not yet live!"
        );

        require(
            !isWhitelistOpen || _isLimitExempt[sender] || _isLimitExempt[recipient],
            "Wait for 1 block to disable whitelist!"
        );

        if (isSizeLimitsOpen) {
            if (sender == pair && !isFeeExempt[recipient]) {
                require(
                    amount <= maxTransactionAmount,
                    "Buy transfer amount exceeds the maxTransactionAmount."
                );
            } else if (recipient == pair && !isFeeExempt[sender]) {
                require(
                    amount <= maxTransactionAmount,
                    "Sell transfer amount exceeds the maxTransactionAmount."
                );
            }

            if (
                !isFeeExempt[sender] &&
                recipient != address(router) &&
                recipient != address(pair) &&
                !isFeeExempt[recipient]
            ) {
                require(
                    _balances[recipient].add(amount) <= maxWalletSize,
                    "Transfer amount exceeds the maxWalletSize."
                );
            }
        }

        if(shouldSwapBack()){ swapBack(); }

        //Exchange tokens
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(sender) ? takeFee(sender, amount) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);


        // Dividend tracker
        if(!isDividendExempt[sender]) {
            try distributor.setShare(sender, _balances[sender]) {} catch {}
        }

        if(!isDividendExempt[recipient]) {
            try distributor.setShare(recipient, _balances[recipient]) {} catch {} 
        }

        try distributor.process(distributorGas) {} catch {}

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }
    
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function checkTxLimit(address sender, uint256 amount) internal view {
        require(amount <= maxTransactionAmount || _isLimitExempt[sender], "TX Limit Exceeded");
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !isFeeExempt[sender];
    }

    function takeFee(address sender, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount.mul(totalFee).div(feeDenominator);
        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);

        return amount.sub(feeAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapTokensAtAmount;
    }

    function swapTokensForEth(uint256 tokenAmount, address _to) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            _to,
            block.timestamp
        );

    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // add the liquidity
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    function swapBack() internal swapping {

        uint256 lpToken = swapTokensAtAmount.mul(liquidityFee).div(totalFee);
        uint256 half = lpToken.div(2);
        uint256 amountETHForLP = lpToken.sub(half);

        uint256 amountLPETH = address(this).balance;

        swapTokensForEth(amountETHForLP, address(this));

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(amountLPETH);

        // add liquidity to uniswap
        addLiquidity(half, newBalance);
        
        uint256 contractTokenBalance = _balances[address(this)];

        swapTokensForEth(contractTokenBalance, address(this));

        uint256 amountEth = address(this).balance;

        uint256 amountETHReflection = amountEth.mul(rewardFee).div(totalFee);
        uint256 amountETHMarketing = amountEth.mul(marketingFee).div(totalFee);

        if(totalFee > 0) {
            try distributor.deposit{value: amountETHReflection}() {} catch {}
            (bool tmpSuccess,) = payable(marketingWallet).call{value: amountETHMarketing, gas: 30000}("");
        
            // Supress warning msg
            tmpSuccess = false;
        }
    }

    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function isExcludedFromDividends(
        address account
    ) public view returns (bool) {
        return isDividendExempt[account];
    }

    function isExcludedFromFees(
        address account
    ) public view returns (bool) {
        return isFeeExempt[account];
    }

    function excludeFromFees(address holder, bool exempt) external onlyOwner {
        isFeeExempt[holder] = exempt;

        emit ExcludeFromFees(holder, exempt);
    }

    function setIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        isTxLimitExempt[holder] = exempt;
    }

    function updateFee(
        uint256 _rewardFee,
        uint256 _liquidityFee,
        uint256 _marketingFee
    ) external onlyOwner {
        uint256 check = _rewardFee.add(_liquidityFee).add(_marketingFee);
        require(check <= 15, "Exceeded totalFees Limit");
        totalFee = check;
        rewardFee = _rewardFee;
        liquidityFee = _liquidityFee;
        marketingFee = _marketingFee;
    }

    function updateMarketingWallet(
        address payable _newWallet
    ) external onlyOwner {
        require(
            _newWallet != marketingWallet,
            " wallet is already set to marketing address"
        );
        require(_newWallet != address(0), " wallet cannot be zero address");
        isFeeExempt[_newWallet] = true;
        marketingWallet = _newWallet;
    }

    function transferForeignToken(
        address _token
    ) external returns (bool _sent) {
        require(_token != address(0), "_token address cannot be 0");
        require(
            _token != address(this),
            "_token address cannot be native token"
        );
        uint256 _contractBalance = IERC20(_token).balanceOf(address(this));
        _sent = IERC20(_token).transfer(
            address(marketingWallet),
            _contractBalance
        );
        emit TransferForeignToken(_token, _contractBalance);
    }

    // withdraw ETH stucked token contract
    function withdrawStuckETH() external {
        bool success;
        (success, ) = address(marketingWallet).call{
            value: address(this).balance
        }("");
    }

    function exemptFromLimit(
        address[] memory accounts,
        bool exempt
    ) external onlyOwner {
        require(accounts.length < 25, "Exceeded numbers of accepted addr");

        for (uint i = 0; i < accounts.length; i++) {
            address wallet = accounts[i];
            require(
                _isLimitExempt[wallet] != exempt,
                "An addr already exempted"
            );
            _isLimitExempt[wallet] = exempt;
        }
    }
    
    function setSwapBackSettings(bool _enabled, uint256 _amount) external onlyOwner {
        swapEnabled = _enabled;
        swapTokensAtAmount = _amount;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyOwner {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setDistributorSettings(uint256 gas) external onlyOwner {
        require(gas < 750000);
        distributorGas = gas;
    }
}