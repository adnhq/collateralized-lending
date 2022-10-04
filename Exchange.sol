// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// REVERT LOG: 
// e00 : Incorrect input/output amount
// e01 : Collateral percentage out of range
// e02 : No unpaid interest
// e03 : Caller is not the borrower of given txId
// e04 : Refinance not applicable for given txId
// e05 : Interest has been paid within 90 days
// e06 : Input collateral amount exceeds accrued interest
// e07 : No amount to reinstate

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Exchange is Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _txId;

    AggregatorV3Interface internal feed0;
    AggregatorV3Interface internal feed1;

    uint public constant MIN_COLLAT = 120;
    uint public constant MAX_COLLAT = 200;
    uint public constant REFI_FEE = 10; 

    IERC20 public constant token0 = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c); 
    IERC20 public constant token1 = IERC20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8); 
    IERC20 public distToken;

    struct Loan {
        uint amountLoaned;
        uint amountCollateral;
        uint collatPercentage;
        uint lastPaidTimestamp;
        uint amountInterest;
        address loanee;
        bool collat0; 
    }

    mapping(uint => Loan) private _loans;
    
    event TokensLoaned(address indexed recipient, uint id, uint256 amount, uint256 time);
    event InterestPaid(uint id, address payee, uint amount, uint time);

    constructor(
        address _distToken,
        address _feed0,
        address _feed1
    ) {
        feed0 = AggregatorV3Interface(_feed0);
        feed1 = AggregatorV3Interface(_feed1); 
        distToken = IERC20(_distToken);
    }

    function getRate0() public view returns (uint) {
        ( ,int price, , , ) = feed0.latestRoundData();
        return uint(price) / 1e8; 
    }

    function getRate1() public view returns (uint) {
        ( ,int price, , , ) = feed1.latestRoundData();
        return uint(price) / 1e8; 
    }
    
    function totalLended() external view returns (uint) {
        return _txId.current();

    }

    function takeLoan0(uint256 amountInput, uint256 amountOutput) external {
        require(amountInput > 0 && amountOutput > 0, "e00");

        uint collateral = (amountInput * getRate0() * 100) / amountOutput;
        require(collateral >= MIN_COLLAT && collateral <= MAX_COLLAT, "e01");

        _txId.increment();
        uint256 cId = _txId.current();

        _loans[cId] = Loan(
            amountOutput, 
            amountInput, 
            collateral, 
            block.timestamp, 
            0,
            msg.sender, 
            true
        );

        token0.transferFrom(msg.sender, address(this), amountInput);

        distToken.transfer(msg.sender, amountOutput);

        emit TokensLoaned(msg.sender, cId, amountOutput, block.timestamp);
    }

    function takeLoan1(uint256 amountInput, uint256 amountOutput) external {
        require(amountInput > 0 && amountOutput > 0, "e00");

        uint collateral = (amountInput * getRate1() * 100) / amountOutput;
        require(collateral >= MIN_COLLAT && collateral <= MAX_COLLAT, "e01");

        _txId.increment();
        uint256 cId = _txId.current();

        _loans[cId] = Loan(
            amountOutput, 
            amountInput, 
            collateral, 
            block.timestamp, 
            0,
            msg.sender, 
            false
        );

        token1.transferFrom(msg.sender, address(this), amountInput);

        distToken.transfer(msg.sender, amountOutput);

        emit TokensLoaned(msg.sender, cId, amountOutput, block.timestamp);
    }

    function _getInterestPercentage(uint collateral) internal pure returns (uint256) {
        if(collateral >= 190 && collateral <= 200)
            return 1;
        else if(collateral >= 170 && collateral < 190)
            return 2;
        else if(collateral >= 150 && collateral < 170)
            return 3;
        else if(collateral >= 130 && collateral < 150)
            return 4;
        else if(collateral >= 120 && collateral < 130)
            return 5;
        else
            revert("e01");
    }

    function payInterest(uint txId) external {
        uint totalInterest = getTotalInterest(txId);
        require(totalInterest > 0, "e02"); 

        _loans[txId].lastPaidTimestamp = block.timestamp;
        _loans[txId].amountInterest = 0;
        
        distToken.transferFrom(msg.sender, owner(), totalInterest);

        emit InterestPaid(txId, msg.sender, totalInterest, block.timestamp);
    }

    function reimburseLoan(uint txId, uint amount) external { 
        Loan storage loan = _loans[txId];

        require(msg.sender == loan.loanee, "e03");
        require(amount > 0 && amount <= loan.amountCollateral, "e00");

        loan.amountInterest = getTotalInterest(txId);

        loan.lastPaidTimestamp = block.timestamp;
        loan.amountCollateral -= amount;

        if(loan.amountCollateral == 0) delete _loans[txId];
        
        distToken.transferFrom(msg.sender, address(this), amount);
    }

    function refinance(uint txId) external {
        Loan storage loan = _loans[txId];
        require(msg.sender == loan.loanee, "e03");

        uint rate = loan.collat0 ? getRate0() : getRate1();
        uint fee = (loan.amountLoaned * REFI_FEE) / 100;
        uint claimable = ((rate * loan.amountCollateral * 100) / loan.collatPercentage) - loan.amountLoaned - fee;

        require(claimable > 0, "e04");

        loan.amountInterest = getTotalInterest(txId);
        loan.lastPaidTimestamp = block.timestamp;
        loan.amountLoaned += claimable;

        distToken.transfer(owner(), fee);
        distToken.transfer(msg.sender, claimable);
    }

    function getTotalInterest(uint txId) public view returns (uint256) {
        uint annualInterest = (_loans[txId].amountLoaned * _getInterestPercentage(_loans[txId].collatPercentage)) / 100;
        uint currentInterest = (annualInterest * (block.timestamp - _loans[txId].lastPaidTimestamp)) / 365 days;
        return currentInterest + _loans[txId].amountInterest;
    }

    function getLoanInfo(uint txId) external view returns (Loan memory) {
        return _loans[txId]; 
    }
    
    /* | --- ONLY OWNER --- | */

    function collectInterest(uint txId, uint collateralAmount) external onlyOwner {
        Loan storage loan = _loans[txId];
        require(block.timestamp - loan.lastPaidTimestamp >= 90 days, "e05");
        
        uint cInterest = getTotalInterest(txId);
        uint amountStable = collateralAmount * (loan.collat0 ? getRate0() : getRate1());
        require(cInterest >= amountStable, "e06");
        
        loan.lastPaidTimestamp = block.timestamp;
        loan.amountInterest = cInterest - amountStable;
        loan.amountCollateral -= collateralAmount;

        if(loan.collat0) 
            token0.transfer(owner(), collateralAmount);
        else 
            token1.transfer(owner(), collateralAmount);
    }

    function reinstate(uint txId) external onlyOwner {
        uint256 amount = _loans[txId].amountCollateral;
        require(amount > 0, "e07");

        address loanee = _loans[txId].loanee;
        bool collat0 = _loans[txId].collat0;

        delete _loans[txId];

        if(collat0) 
            token0.transfer(loanee, amount);
        else 
            token1.transfer(loanee, amount);

    }

    function withdrawTokens(uint amount) external onlyOwner {
        distToken.transfer(msg.sender, amount);
    }

}
