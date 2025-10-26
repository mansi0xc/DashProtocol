# Test connection
from web3 import Web3
from dotenv import load_dotenv
load_dotenv()
import os

ALCHEMY_RPC_URL = os.getenv("ALCHEMY_RPC_URL")  # Add to your .env
w3 = Web3(Web3.HTTPProvider(ALCHEMY_RPC_URL))

print(f"RPC URL: {ALCHEMY_RPC_URL}")
print(f"Connected: {w3.is_connected()}")
print(f"Chain ID: {w3.eth.chain_id}")  # Should print 11155111 for Sepolia
print(f"Latest Block: {w3.eth.block_number}")

# Verify it's actually Sepolia
if w3.eth.chain_id != 11155111:
    raise ValueError(f"Wrong network! Expected Sepolia (11155111), got {w3.eth.chain_id}")