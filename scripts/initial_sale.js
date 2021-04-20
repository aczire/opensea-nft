const opensea = require("opensea-js");
const OpenSeaPort = opensea.OpenSeaPort;
const Network = opensea.Network;
const MnemonicWalletSubprovider = require("@0x/subproviders")
  .MnemonicWalletSubprovider;
const RPCSubprovider = require("web3-provider-engine/subproviders/rpc");
const Web3ProviderEngine = require("web3-provider-engine");

const MNEMONIC = process.env.MNEMONIC;
const NODE_API_KEY = process.env.INFURA_KEY || process.env.ALCHEMY_KEY;
const isInfura = !!process.env.INFURA_KEY;
const FACTORY_CONTRACT_ADDRESS = process.env.FACTORY_CONTRACT_ADDRESS;
const OWNER_ADDRESS = process.env.OWNER_ADDRESS;
const NETWORK = process.env.NETWORK;
const API_KEY = process.env.API_KEY || ""; // API key is optional but useful if you're doing a high volume of requests.

const DUTCH_AUCTION_OPTION_ID = "1";
const DUTCH_AUCTION_START_AMOUNT = 100;
const DUTCH_AUCTION_END_AMOUNT = 50;
const NUM_DUTCH_AUCTIONS = 3;

const FIXED_PRICE_OPTION_ID = "2";
const NUM_FIXED_PRICE_AUCTIONS = 10;
const FIXED_PRICE = 0.05;

if (!MNEMONIC || !NODE_API_KEY || !NETWORK || !OWNER_ADDRESS) {
  console.error(
    "Please set a mnemonic, Alchemy/Infura key, owner, network, API key, nft contract, and factory contract address."
  );
  return;
}

if (!FACTORY_CONTRACT_ADDRESS) {
  console.error("Please specify a factory contract address.");
  return;
}

const BASE_DERIVATION_PATH = `44'/60'/0'/0`;

const mnemonicWalletSubprovider = new MnemonicWalletSubprovider({
  mnemonic: MNEMONIC,
  baseDerivationPath: BASE_DERIVATION_PATH,
});
const network =
  NETWORK === "mainnet" || NETWORK === "live" ? "mainnet" : "rinkeby";
const infuraRpcSubprovider = new RPCSubprovider({
  rpcUrl: isInfura
    ? "https://" + network + ".infura.io/v3/" + NODE_API_KEY
    : "https://eth-" + network + ".alchemyapi.io/v2/" + NODE_API_KEY,
});

const providerEngine = new Web3ProviderEngine();
providerEngine.addProvider(mnemonicWalletSubprovider);
providerEngine.addProvider(infuraRpcSubprovider);
providerEngine.start();

const seaport = new OpenSeaPort(
  providerEngine,
  {
    networkName:
      NETWORK === "mainnet" || NETWORK === "live"
        ? Network.Main
        : Network.Rinkeby,
    apiKey: API_KEY,
  },
  (arg) => console.log(arg)
);

async function main() {
  // Example: many fixed price auctions for a factory option.
  console.log("Creating fixed price auctions...");
  const fixedSellOrders = await seaport.createFactorySellOrders({
    assets: [
      {
        tokenId: FIXED_PRICE_OPTION_ID,
        tokenAddress: FACTORY_CONTRACT_ADDRESS,
      },
    ],
    accountAddress: OWNER_ADDRESS,
    startAmount: FIXED_PRICE,
    numberOfOrders: NUM_FIXED_PRICE_AUCTIONS,
  });
  console.log(
    `Successfully made ${fixedSellOrders.length} fixed-price sell orders! ${fixedSellOrders[0].asset.openseaLink}\n`
  );

  // Example: many fixed price auctions for multiple factory options.
  console.log("Creating fixed price auctions...");
  const fixedSellOrdersTwo = await seaport.createFactorySellOrders({
    assets: [
      { tokenId: "3", tokenAddress: FACTORY_CONTRACT_ADDRESS },
      { tokenId: "4", tokenAddress: FACTORY_CONTRACT_ADDRESS },
      { tokenId: "5", tokenAddress: FACTORY_CONTRACT_ADDRESS },
      { tokenId: "6", tokenAddress: FACTORY_CONTRACT_ADDRESS },
    ],
    factoryAddress: FACTORY_CONTRACT_ADDRESS,
    accountAddress: OWNER_ADDRESS,
    startAmount: FIXED_PRICE,
    numberOfOrders: NUM_FIXED_PRICE_AUCTIONS,
  });
  console.log(
    `Successfully made ${fixedSellOrdersTwo.length} fixed-price sell orders for multiple assets at once! ${fixedSellOrders[0].asset.openseaLink}\n`
  );

  // Example: many declining Dutch auction for a factory.
  console.log("Creating dutch auctions...");

  // Expire one day from now
  const expirationTime = Math.round(Date.now() / 1000 + 60 * 60 * 24);
  const dutchSellOrders = await seaport.createFactorySellOrders({
    assets: [
      {
        tokenId: DUTCH_AUCTION_OPTION_ID,
        tokenAddress: FACTORY_CONTRACT_ADDRESS,
      },
    ],
    accountAddress: OWNER_ADDRESS,
    startAmount: DUTCH_AUCTION_START_AMOUNT,
    endAmount: DUTCH_AUCTION_END_AMOUNT,
    expirationTime: expirationTime,
    numberOfOrders: NUM_DUTCH_AUCTIONS,
  });
  console.log(
    `Successfully made ${dutchSellOrders.length} Dutch-auction sell orders! ${dutchSellOrders[0].asset.openseaLink}\n`
  );
}

main();
