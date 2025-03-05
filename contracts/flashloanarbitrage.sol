// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Aave V3 Flash Loan imports
import "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Uniswap V2-style Router interface (used for both Uniswap and SushiSwap)
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

contract FlashLoanArbitrage is FlashLoanSimpleReceiverBase {
    address public immutable owner;
    IERC20 public immutable dai; // DAI token
    IERC20 public immutable usdc; // USDC token

    // DEX Router addresses (replace with actual addresses for your network)
    address public constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // Uniswap V2 Router
    address public constant SUSHISWAP_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // SushiSwap Router

    // Token addresses (replace with actual addresses for your network)
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI on Ethereum Mainnet
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC on Ethereum Mainnet

    // Events for logging
    event FlashLoanRequested(uint256 amount, uint256 timestamp);
    event ArbitrageExecuted(uint256 daiBorrowed, uint256 daiReceived, bool profitable);
    event ProfitWithdrawn(address token, uint256 amount);

    constructor(address _addressProvider) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)) {
        owner = msg.sender;
        dai = IERC20(DAI);
        usdc = IERC20(USDC);
    }

    // Initiate the flash loan
    function requestFlashLoan(uint256 amount, uint256 minProfit) external {
        require(msg.sender == owner, "Only owner can request flash loan");
        require(amount > 0, "Amount must be greater than 0");

        emit FlashLoanRequested(amount, block.timestamp);

        // Request flash loan from Aave
        POOL.flashLoanSimple(
            address(this), // Receiver
            DAI, // Asset to borrow (DAI)
            amount, // Amount
            abi.encode(amount, minProfit), // Params: loan amount and minimum profit
            0 // Referral code
        );
    }

    // Aave callback function after receiving the loan
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address /* initiator */,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(POOL), "Caller must be Aave Pool");
        require(asset == DAI, "Unexpected asset");

        // Decode params
        (uint256 loanAmount, uint256 minProfit) = abi.decode(params, (uint256, uint256));

        // Execute arbitrage
        (bool profitable, uint256 daiReceived) = executeArbitrage(loanAmount);

        // Calculate total debt (loan + Aave fee)
        uint256 totalDebt = amount + premium;

        // Ensure profitability and sufficient funds to repay
        require(profitable && daiReceived >= totalDebt + minProfit, "Arbitrage not profitable enough");
        require(dai.balanceOf(address(this)) >= totalDebt, "Insufficient DAI to repay loan");

        // Approve Aave to pull the repayment amount
        dai.approve(address(POOL), totalDebt);

        emit ArbitrageExecuted(loanAmount, daiReceived, profitable);
        return true; // Indicates successful repayment
    }

    // Execute arbitrage: DAI -> USDC on one DEX, USDC -> DAI on the other
    function executeArbitrage(uint256 amount) internal returns (bool profitable, uint256 daiReceived) {
        // Define trade paths
        address[] memory path1 = new address[](2); // DAI -> USDC
        path1[0] = DAI;
        path1[1] = USDC;

        address[] memory path2 = new address[](2); // USDC -> DAI
        path2[0] = USDC;
        path2[1] = DAI;

        // Check prices to determine trade direction
        uint256 uniswapOut = getAmountOut(UNISWAP_ROUTER, amount, path1);
        uint256 sushiswapOut = getAmountOut(SUSHISWAP_ROUTER, amount, path1);

        if (uniswapOut > sushiswapOut) {
            // Buy USDC on SushiSwap, sell on Uniswap
            daiReceived = tradeSushiToUni(amount, path1, path2);
        } else {
            // Buy USDC on Uniswap, sell on SushiSwap
            daiReceived = tradeUniToSushi(amount, path1, path2);
        }

        // Check if trade was profitable
        profitable = daiReceived > amount;
    }

    // Trade: DAI -> USDC on SushiSwap, USDC -> DAI on Uniswap
    function tradeSushiToUni(uint256 amount, address[] memory path1, address[] memory path2) internal returns (uint256) {
        // Approve SushiSwap to spend DAI
        dai.approve(SUSHISWAP_ROUTER, amount);

        // Swap DAI -> USDC on SushiSwap
        uint256[] memory amountsOut1 = IUniswapV2Router(SUSHISWAP_ROUTER).swapExactTokensForTokens(
            amount,
            getAmountOut(SUSHISWAP_ROUTER, amount, path1) * 98 / 100, // 2% slippage tolerance
            path1,
            address(this),
            block.timestamp + 300 // Deadline: 5 minutes
        );

        uint256 usdcReceived = amountsOut1[1];

        // Approve Uniswap to spend USDC
        usdc.approve(UNISWAP_ROUTER, usdcReceived);

        // Swap USDC -> DAI on Uniswap
        uint256[] memory amountsOut2 = IUniswapV2Router(UNISWAP_ROUTER).swapExactTokensForTokens(
            usdcReceived,
            getAmountOut(UNISWAP_ROUTER, usdcReceived, path2) * 98 / 100, // 2% slippage tolerance
            path2,
            address(this),
            block.timestamp + 300
        );

        return amountsOut2[1]; // DAI received
    }

    // Trade: DAI -> USDC on Uniswap, USDC -> DAI on SushiSwap
    function tradeUniToSushi(uint256 amount, address[] memory path1, address[] memory path2) internal returns (uint256) {
        // Approve Uniswap to spend DAI
        dai.approve(UNISWAP_ROUTER, amount);

        // Swap DAI -> USDC on Uniswap
        uint256[] memory amountsOut1 = IUniswapV2Router(UNISWAP_ROUTER).swapExactTokensForTokens(
            amount,
            getAmountOut(UNISWAP_ROUTER, amount, path1) * 98 / 100, // 2% slippage tolerance
            path1,
            address(this),
            block.timestamp + 300
        );

        uint256 usdcReceived = amountsOut1[1];

        // Approve SushiSwap to spend USDC
        usdc.approve(SUSHISWAP_ROUTER, usdcReceived);

        // Swap USDC -> DAI on SushiSwap
        uint256[] memory amountsOut2 = IUniswapV2Router(SUSHISWAP_ROUTER).swapExactTokensForTokens(
            usdcReceived,
            getAmountOut(SUSHISWAP_ROUTER, usdcReceived, path2) * 98 / 100, // 2% slippage tolerance
            path2,
            address(this),
            block.timestamp + 300
        );

        return amountsOut2[1]; // DAI received
    }

    // Helper function to get expected output amount
    function getAmountOut(address router, uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amounts = IUniswapV2Router(router).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    // Withdraw profits (only owner)
    function withdraw(address tokenAddress, uint256 amount) external {
        require(msg.sender == owner, "Only owner can withdraw");
        require(amount > 0, "Amount must be greater than 0");
        IERC20(tokenAddress).transfer(owner, amount);
        emit ProfitWithdrawn(tokenAddress, amount);
    }

    // Fallback function to receive ETH (if needed)
    receive() external payable {}
}