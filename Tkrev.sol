// SPDX-License-Identifier: UNLICENSED
// https://ethereum.stackexchange.com/questions/115382/rules-on-choosing-a-solidity-version/115407
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./utils/Interfaces.sol";
// import "hardhat/console.sol";

contract BasicToken is ERC20, ERC20Burnable, Pausable, Ownable, ReentrancyGuard {

    uint256 private constant MAX_NR_FEE_RECIPIENTS = 10;

    // All fees in this contract are expressed in basis points, which is 1/10000.
    // See https://www.investopedia.com/terms/b/basispoint.asp
    uint256 private constant MAX_BASIS_POINTS = 10000;

    // A struct to hold data per fee recipient. A fee recipient is a wallet address that is
    // entitled to receive a fee for each transaction that occurs with this token.
    // uint16 buyFee - fee to apply on buy transfer (against the configured pancake pair)
    // uint16 sellFee - fee to apply on sell transfer (against the configured pancake pair)
    // uint16 otherFee - fee to apply on any other transfer
    // bool exists -  Must always be true so we can test for the recipient to exist
    // bool swap - Set to true if the user will receive fees in BNB
    // uint256 amountToSwapDeposit - fee balance collected for the recipient and not yet swapped to BNB and paid
    struct FeeRecipient {
        uint16 buyFee;
        uint16 sellFee;
        uint16 otherFee;
        bool exists;
        bool swap;
        uint256 amountToSwapDeposit;
    }

    // Mapping and array with feeRecipients. Note that the mapping and array must be kept in sync.
    mapping(address => FeeRecipient) public feeRecipients;

    // Array of feeRecipientAddresses so we can loop through them, that is not possible with the feeRecipients mapping
    address[] public feeRecipientAddresses;

    // Mapping of nonFeePayers. We don't need to loop through them, therefore we don't need an array.
    mapping(address => bool) public nonFeePayers;

    uint8 private intDecimals;

    // Burn fee in basis points
    uint16 public burnFee;

    // AutoLP fee (for buy and sell operations)
    uint16 public buyLiquidityFee;
    uint16 public sellLiquidityFee;

    // The amount of tokens withhold by the contract that must be added to the liquidityPool (when higher than or equals to minLPDeposit)
    uint256 public liquidityFeeDeposit;

    // The pancake router and pair
    IPancakeRouter public pancakeRouter;
    IPancakePair public pancakePair;

    // Amount minted so far
    uint256 public mintedAmount;

    // Amount burned so far
    uint256 public burnedSupply;

    // Avoids paying fees recursively
    bool private noFeesApplied;

    // Does owner pay fees?
    bool public ownerPaysFees = false;

    // Maximum value for a transaction;
    // if higher, the transaction is reverted
    uint256 public maxBuyAmount;
    uint256 public maxSellAmount;

    // Feature flags - can only be set by the constructor
    bool canMint;
    bool canBurn;

    // ======
    // Events
    // ======
    event SetBurnFee(uint16 oldFee, uint16 newFee);
    event SetLiquidityFee(string feeType, uint16 newFee);
    event SetMinLPDeposit(uint256 minLPDeposit, uint256 newMinLpDeposit);
    event SetMinSwappedDeposit(uint256 minSwappedDeposit, uint256 newMinSwappedDeposit);
    event AddFeeRecipient(address recipient, uint16 buyFee, uint16 sellFee, uint16 otherFee, bool swap);
    event SetMaxBuyAmount(uint256 oldFee, uint256 newFee);
    event SetMaxSellAmount(uint256 oldFee, uint256 newFee);
    event RemoveFeeRecipient(address recipient);
    event AddNonFeePayer(address recipient);
    event RemoveNonFeePayer(address recipient);
    event PayFeesInBnb(address recipient, uint256 bnbAmount);

    // ===========
    // Constructor
    // ===========
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 mintAmount_,
        address controller_,
        uint16 burnFee_,
        uint16 liquidityFee_,
        address pancakeRouter_,
        bool canMint_,
        bool canBurn_
    ) ERC20(name_, symbol_) {
        // Mint an initial amount of tokens to the controller account
        _mint(controller_, mintAmount_);

        intDecimals = decimals_;

        // Store the amount minted, to be used in tracking burned amount
        mintedAmount = mintAmount_;

        // Immediately transfer the ownership to the "controller"
        transferOwnership(controller_);

        // Initialize state variables explicitly
        canMint = canMint_;
        canBurn = canBurn_;

        // If canBurn is false, we set burnFee to 0
        burnFee = canBurn ? burnFee_ : 0;

        buyLiquidityFee = liquidityFee_;
        sellLiquidityFee = liquidityFee_;
        maxBuyAmount = 0;
        maxSellAmount = 0;
        burnedSupply = 0;

        // Create the pancake pair and write the address into the immutable contract variable
        // The pair created is between this token and the Wrapped Native token (wBnb really) in Pancake
        pancakeRouter = IPancakeRouter(pancakeRouter_);
        pancakePair = IPancakePair(IPancakeFactory(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH()));
    }

    // Set decimals specified in the constructor
    function decimals() public view override returns (uint8) {
        return intDecimals;
    }

    // Receive BNB
    // Needed for pancake router to send us BNB when we swapToBNB
    receive() external payable {
    }

    IReflector reflector;
    function setReflector(address _r) external onlyOwner {
        reflector = IReflector(_r);
    }
    function notifyReflector(address _s, address _r) internal {
        if (address(reflector) != address(0)) {
            reflector.trackTokenToReflectTransfer(_s, _r);
        }
    }

    // =================
    // Transfer function
    // =================

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    )
    internal override
    whenNotPaused
    {
        // console.log("---- transfer header");
        // console.log("BasicToken._transfer Sender/Recipient/Amunt", sender, recipient, amount);
        // console.log("BasicToken._transfer Apply fees?", !noFeesApplied);
        // console.log("BasicToken._transfer Balance in TK:", balanceOf(address(this)));
        // console.log("BasicToken._transfer Balance BNB  :", address(this).balance);
        // console.log("----");

        uint256 amountRemaining = amount;

        uint16 liquidityFee = getLiquidityFee(sender, recipient);

        // Check if limits exceed
        if (maxBuyAmount > 0 && isBuy(sender)) {
            // Buy transaction
            require(amount <= maxBuyAmount, "maxBuyAmount Limit Exceeded");
        } else if (maxSellAmount > 0 && isSell(recipient)) {
            // Sell transaction
            require(amount <= maxSellAmount, "maxSellAmount Limit Exceeded");
        }

        // Shall we pay fees?
        // - Is sender or recipient in the nonFeePayers list?
        // - Is sender the contract itself? This could be a fee payment (and block reentrancy)
        // - Is sender or recipient the owner, assuming the ownerPaysFees=true ?
        // - Is noFeesApplied==false, to block re-entrancy?
        if (
            !nonFeePayers[sender]
        && !nonFeePayers[recipient]
        && sender != address(this)
        && (ownerPaysFees || (sender != owner() && recipient != owner()))
        && !noFeesApplied
        ) {
            // console.log("BasicToken._transfer distributing fees!");

            // How many tokens are paid in fees (for each fee type)
            uint256 fee;
            // How many tokens need to be swapped with Uniswap router
            uint256 toSwap = 0;
            // Whether addLiquidity must be done or not
            bool performAddLiquidity = false;

            for (uint8 i = 0; i < feeRecipientAddresses.length; i++) {
                address feeRecipientAddress = feeRecipientAddresses[i];

                FeeRecipient memory feeRecipient = feeRecipients[feeRecipientAddress];
                if (feeRecipient.exists) {
                    uint16 basisPoints = 0;
                    if (isSell(recipient)) {
                        basisPoints = feeRecipient.sellFee;
                    } else if (isBuy(sender)) {
                        basisPoints = feeRecipient.buyFee;
                    } else {
                        basisPoints = feeRecipient.otherFee;
                    }
                    fee = (amount * basisPoints) / MAX_BASIS_POINTS;
                    if (fee > 0 && fee <= amountRemaining) {
                        amountRemaining = amountRemaining - fee;
                        // Collect fees for payment in BNB
                        if (feeRecipient.swap) {
                            feeRecipients[feeRecipientAddress].amountToSwapDeposit += fee;
                            if (!isBuy(sender)) {
                                toSwap += feeRecipients[feeRecipientAddress].amountToSwapDeposit;
                            }
                            // console.log("feeRecipient accumulated fees (in token) with payment in BNB", feeRecipientAddress, feeRecipients[feeRecipientAddress].amountToSwapDeposit);
                            feeRecipientAddress = address(this);
                        }
                        // console.log("Paying feeRecipient");
                        super._transfer(sender, feeRecipientAddress, fee);
                        // console.log("BasicToken._transfer - Paying feeRecipient done", feeRecipientAddress, fee);
                    }
                }
            }
            // Burn fees
            if (burnFee > 0) {
                fee = (amount * burnFee) / MAX_BASIS_POINTS;
                if (fee > 0 && fee <= amountRemaining) {
                    // console.log("Burning");
                    _burn(sender, fee);
                    // console.log("Burning done");
                    amountRemaining -= fee;
                    burnedSupply += fee;
                }
            }
            // First, transfer tokens into the contract, and update 
            // liquidityFeeDeposit. Then try to swap and addLiquidity; if pre-flight (amountOut) is 0, tokens will be swapped next time
            // Note - swap and addLiquidity are done for any transfer except buy (to avoid uniswap reentrancy guard and failure). But even for buys, tokens are stored in the contract, waiting for a non-buy operation to add it as liquidity to the pool.
            if (liquidityFee > 0) {
                fee = (amount * liquidityFee) / MAX_BASIS_POINTS;
                if (fee > 0 && fee <= amountRemaining) {
                    // console.log("BasicToken._transfer - Sending liquidity fee", fee);
                    super._transfer(sender, address(this), fee);
                    // console.log("BasicToken._transfer - Sending liquidity fee done");
                    // Send the fee to this contract
                    amountRemaining -= fee;
                    liquidityFeeDeposit += fee;
                }

                if (!isBuy(sender) && liquidityFeeDeposit > 0) {
                    toSwap += liquidityFeeDeposit / 2;
                    performAddLiquidity = true;
                    // console.log("BasicToken._transfer - Set performAddLiquidity=true, with deposit", liquidityFeeDeposit);
                }
            }

            // Swap some tokens to BNB, using the Uniswap Router
            // console.log("BasicToken._transfer - toSwap:", toSwap);
            if (toSwap > 0) {
                payFeesInBnb(toSwap, performAddLiquidity);
            }
        }
        super._transfer(sender, recipient, amountRemaining);
        notifyReflector(sender, recipient);
        // console.log("BasicToken._transfer done");
    }

    // =========
    // Modifiers
    // =========

    modifier doNotApplyFees {
        noFeesApplied = true;
        _;
        noFeesApplied = false;
    }

    // ===============
    // Owner functions
    // ===============

    function mint(uint256 mintAmount) external onlyOwner {
        require(canMint, "Minting is not available");
        require(mintAmount > 0, "mintAmount must be higher than 0");
        mintedAmount += mintAmount;
        _mint(owner(), mintAmount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function isFeeValid(uint16 fee, string memory feeType) internal view {
        require(fee <= MAX_BASIS_POINTS, string.concat(feeType, " fee cannot be greater than 10000"));

        // Check if the total fees across all recipients is higher than 100%
        uint256 totalFees = fee + burnFee + buyLiquidityFee;
        for (uint8 i = 0; i < feeRecipientAddresses.length; i++) {
            address feeRecipientAddress = feeRecipientAddresses[i];
            FeeRecipient memory feeRecipient = feeRecipients[feeRecipientAddress];
            if (compareStrings(feeType, "Buy")) {
                totalFees += feeRecipient.buyFee;
            } else if (compareStrings(feeType, "Sell")) {
                totalFees += feeRecipient.buyFee;
            } else if (compareStrings(feeType, "Other")) {
                totalFees += feeRecipient.otherFee;
            }
        }
        require(
            totalFees <= 10000,
            "Reached 100% of fees!");
    }

    // Add a new fee recipient with a fee of basisPoints
    function addFeeRecipient(address recipient, uint16 buyFee, uint16 sellFee, uint16 otherFee, bool swap) external onlyOwner {
        require(recipient != address(0), "Recipient cannot be 0");
        require(!feeRecipients[recipient].exists, "Recipient already exists");
        require(feeRecipientAddresses.length < MAX_NR_FEE_RECIPIENTS, "Max number of recipients reached");
        require(buyFee != 0, "Buy fee cannot be 0");
        require(sellFee != 0, "Sell fee cannot be 0");
        isFeeValid(buyFee,"Buy");
        isFeeValid(sellFee,"Sell");
        isFeeValid(otherFee,"Other");

        feeRecipients[recipient] = FeeRecipient(buyFee, sellFee, otherFee, true, swap, 0);
        feeRecipientAddresses.push(recipient);
        emit AddFeeRecipient(recipient, buyFee, sellFee, otherFee, swap);
    }

    // Remove an existing fee recipient
    function removeFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "Recipient cannot be 0");
        require(feeRecipients[recipient].exists, "Recipient does not exist");
        delete feeRecipients[recipient];
        emit RemoveFeeRecipient(recipient);

        // Loop the array of addresses so we can remove the _recipient
        for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
            if (feeRecipientAddresses[i] != recipient) continue;
            if (i != feeRecipientAddresses.length - 1) {
                feeRecipientAddresses[i] = feeRecipientAddresses[feeRecipientAddresses.length - 1];
            }
            feeRecipientAddresses.pop();
        }
    }

    function addNonFeePayer(address nonFeePayer) external onlyOwner {
        require(nonFeePayer != address(0), "_nonFeePayer cannot be 0");
        require(!nonFeePayers[nonFeePayer], "_nonFeePayer already exists");
        nonFeePayers[nonFeePayer] = true;
        emit AddNonFeePayer(nonFeePayer);
    }

    function removeNonFeePayer(address nonFeePayer) external onlyOwner {
        require(nonFeePayer != address(0), "_nonFeePayer cannot be 0");
        require(nonFeePayers[nonFeePayer], "_nonFeePayer does not exist");
        nonFeePayers[nonFeePayer] = false;
        emit RemoveNonFeePayer(nonFeePayer);
    }

    function setBurnFee(uint16 newBurnFee) external onlyOwner {
        require(canBurn, "Burning is not available");
        require(newBurnFee <= 10000, "_burnFee cannot be greater than 10000");
        emit SetBurnFee(burnFee, newBurnFee);
        burnFee = newBurnFee;
    }

    function setLiquidityFee(uint16 newLiquidityFee) external onlyOwner {
        require(newLiquidityFee <= 10000, "_liquidityFee cannot be greater than 10000");
        emit SetLiquidityFee("all", newLiquidityFee);
        buyLiquidityFee = newLiquidityFee;
        sellLiquidityFee = newLiquidityFee;
    }

    function setBuyLiquidityFee(uint16 newLiquidityFee) external onlyOwner {
        require(newLiquidityFee <= 10000, "_liquidityFee cannot be greater than 10000");
        emit SetLiquidityFee("buy", newLiquidityFee);
        buyLiquidityFee = newLiquidityFee;
    }
    function setSellLiquidityFee(uint16 newLiquidityFee) external onlyOwner {
        require(newLiquidityFee <= 10000, "_liquidityFee cannot be greater than 10000");
        emit SetLiquidityFee("sell", newLiquidityFee);
        sellLiquidityFee = newLiquidityFee;
    }

    function setMaxBuyAmount(uint256 newMaxBuyAmount) external onlyOwner {
        emit SetMaxBuyAmount(maxBuyAmount, newMaxBuyAmount);
        maxBuyAmount = newMaxBuyAmount;
    }

    function setMaxSellAmount(uint256 newMaxSellAmount) external onlyOwner {
        emit SetMaxSellAmount(maxSellAmount, newMaxSellAmount);
        maxSellAmount = newMaxSellAmount;
    }

    function includeOwnerFromFees() external onlyOwner {
        ownerPaysFees = true;
    }
    function excludeOwnerFromFees() external onlyOwner {
        ownerPaysFees = false;
    }

    // ==================
    // Internal functions
    // ==================

    function payFeesInBnb(uint256 toSwap, bool performAddLiquidity) private doNotApplyFees {
        uint256 bnbAmount = swapToBNB(toSwap);
        // console.log("BasicToken._transfer - after swapToBNB", bnbAmount);
        // console.log("BasicToken._transfer - BNB in contract", address(this).balance);
        // Swap happened
        if (bnbAmount > 0) {
            // Now we add liquidity to the pool
            if (performAddLiquidity) {
                uint256 halfLPFeeDeposit = liquidityFeeDeposit / 2;
                // console.log("BasicToken._transfer - perform addLiquidity", liquidityFeeDeposit);
                require(this.approve(address(pancakeRouter), halfLPFeeDeposit), "Approval 1 failed");
                // console.log("BasicToken._transfer - Token in pool:", halfLPFeeDeposit);
                uint256 lpBnbs = bnbAmount * halfLPFeeDeposit / toSwap;
                // console.log("BasicToken._transfer - BNBs in pool :", lpBnbs);

                // console.log("BasicToken._transfer - (LP) to pay ", lpBnbs);
                // console.log("BasicToken._transfer - (LP) balance", address(this).balance);

                pancakeRouter.addLiquidityETH{value: lpBnbs}(
                    address(this),          // Token
                    halfLPFeeDeposit,   // amountTokenDesired
                    0,                  // amountTokenMin
                    0,                  // amountETHMin
                    owner(),            // to
                    block.timestamp         // deadline
                );
                liquidityFeeDeposit = 0;
                // console.log("addLiquidity exit");
            }

            // Now we share BNBs with fee recipients
            // console.log("BasicToken.transfer - pay fees in BNB for recipients:", feeRecipientAddresses.length);
            for (uint8 i = 0; i < feeRecipientAddresses.length; i++) {
                address feeRecipientAddress = feeRecipientAddresses[i];
                FeeRecipient memory feeRecipient = feeRecipients[feeRecipientAddress];
                if (feeRecipient.amountToSwapDeposit > 0) {
                    uint256 feeBnbAmount = bnbAmount * feeRecipient.amountToSwapDeposit / toSwap;
                    // console.log("BasicToken._transfer - Paying fees in BNB!",feeRecipientAddress, feeRecipient.amountToSwapDeposit, feeBnbAmount);
                    if (feeBnbAmount > 0) {
                        // console.log("BasicToken._transfer - to pay ", feeBnbAmount);
                        // console.log("BasicToken._transfer - balance", address(this).balance);

                        // CAREFUL! This could be a point of reentrancy! Make sure that contract owners are aware of the risk, and carefully validate feeRecipients before adding them
                        (bool ret,) = payable(feeRecipientAddress).call{value: feeBnbAmount}("");
                        require(ret, "BasicToken._transfer - Payment of fees in BNBs failed");
                        feeRecipients[feeRecipientAddress].amountToSwapDeposit = 0;
                        // console.log("Paid fees in BNB!",feeRecipientAddress, feeBnbAmount);
                        emit PayFeesInBnb(feeRecipientAddress, feeBnbAmount);
                    }
                }
            }
        }
    }

    // Swaps an amount of this token to BNB using pancake swap
    function swapToBNB(uint256 amount) private returns (uint256 bnbAmount) {
        // Approve spending the tokens
        require(this.approve(address(pancakeRouter), amount), "Approval 2 failed");
        // Create the path variable that the pancake router requires
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeRouter.WETH();

        // Preflight swap, check if the swap is expected to return more than 0 BNB
        uint[] memory amounts = pancakeRouter.getAmountsOut(amount, path);

        if (amounts[1] > 0) {
            // Determine BNB openingBalance before the swap
            uint256 openingBalance = address(this).balance;
            // Execute the swap
            pancakeRouter.swapExactTokensForETH(
                amount, 0, path, address(this), block.timestamp
            );
            // Return the amount of BNB received
            return (address(this).balance - openingBalance);
        } else {
            return 0;
        }
    }

    function getLiquidityFee(address sender, address receiver) private view returns (uint16 liquidityFee) {
        if (isSell(receiver)) {
            return sellLiquidityFee;
        } else if (isBuy(sender)) {
            return buyLiquidityFee;
        } else {
            return 0;
        }
    }

    function isBuy(address sender) internal view returns (bool isBuyFlag) {
        return sender == address(pancakePair);
    }

    function isSell(address receiver) internal view returns (bool isSellFlag) {
        return receiver == address(pancakePair);
    }


}

// ========================================================
// Pancake (Uniswap V2) Router, Factory and Pair interfaces
// ========================================================

interface IPancakeRouter {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakePair { }
