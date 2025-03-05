require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-waffle");
// require('dotenv').config();

module.exports = {
  solidity: "0.8.28",
  // networks: {
  //   hardhat: {
  //     forking: {
  //       url: `https://eth-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`, // Replace with your API key or Infura URL
  //       blockNumber: 16000000, // Optional: Fork from a specific block (recent but stable)
  //     },
  //     accounts: {
  //       mnemonic: "test test test test test test test test test test test junk", // Default Hardhat mnemonic
  //     },
  //   },
  // },
};