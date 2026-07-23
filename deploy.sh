source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $OP_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY