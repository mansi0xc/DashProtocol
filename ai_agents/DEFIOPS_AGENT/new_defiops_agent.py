
# Cell 1: Imports
from langchain_google_genai import ChatGoogleGenerativeAI
from decimal import Decimal, getcontext, InvalidOperation
from pydantic import BaseModel, Field, ValidationError
from typing import TypedDict, Optional, Dict, Any, List
from dataclasses import dataclass, field, asdict
from IPython.display import Image, display
from requests.adapters import HTTPAdapter
from langgraph.graph import StateGraph
from urllib3.util.retry import Retry
from dotenv import load_dotenv
from web3 import Web3
import requests
import logging
import json
import time
import os
import warnings
import whisper
import sounddevice as sd
import numpy as np
import pyttsx3
import tempfile
import scipy.io.wavfile as wav
import re

warnings.filterwarnings("ignore", category=DeprecationWarning)

load_dotenv()

def record_audio(duration=5, samplerate=16000):
    print("Speak now...")
    audio = sd.rec(int(duration * samplerate), samplerate=samplerate, channels=1, dtype=np.float32)
    sd.wait()
    print("Recording stopped.")
    return np.squeeze(audio)

def whisper_transcribe(duration=5, model_name='base'):
    model = whisper.load_model(model_name)
    audio_data = record_audio(duration)
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tempf:
        wav.write(tempf.name, 16000, (audio_data * 32767).astype(np.int16))
        result = model.transcribe(tempf.name)
    text = result["text"].strip()
    print(f"Whisper transcript: {text}")
    return text

def speak_text(text):
    clean_text = re.sub(r'[\\\*\`_\$\[\]\(\)]', '', str(text))  # strip markdown/math
    engine = pyttsx3.init()
    engine.setProperty('rate', 180)
    engine.setProperty('volume', 1.0)
    engine.say(clean_text)
    engine.runAndWait()

# Cell 2: Load Environment
load_dotenv()

# Cell 3: Load Token Map
with open("new_tokens_map.json") as f:
    TOKEN_MAP = json.load(f)

# Cell 4: Configuration
IS_TESTING = False  # Always use Sepolia now

# Sepolia Configuration
SEPOLIA_RPC_URL = os.getenv("ALCHEMY_RPC_URL")  # Add to your .env
w3 = Web3(Web3.HTTPProvider(SEPOLIA_RPC_URL))

# Your deployed contracts
DASH_TOKEN = "0xA4e2553B97FCa8205a8ba108814016e43c9fd32a"
SMS_TOKEN = "0x56C092A883032CE07Bb2b506eFf8EeEe85b444F8"
LIQUIDITY_POOL = "0xE3f19EdE356F5E1C1Ef3499F80F794D2C9F3670a"
DEPLOYER_ADDRESS = "0x34Df0107d4aEE3830899d2AC1F52ACd4015F729B"
CHAIN_ID = 11155111

# CoinGecko still needed for price discovery
COINGECKO_API_URL = os.getenv("COINGECKO_API_URL")
COINGECKO_API_KEY = os.getenv("COINGECKO_API_KEY")

print(f"Connected: {w3.is_connected()}")
print(f"Chain ID: {w3.eth.chain_id}")
print(f"Network: Sepolia")
print(f"Pool Address: {LIQUIDITY_POOL}")

ERC20_ABI = [
    {
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function"
    },
    {
        "constant": False,
        "inputs": [
            {"name": "_spender", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function"
    },
    {
        "constant": True,
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "type": "function"
    },
    {
        "constant": False,
        "inputs": [
            {"name": "_to", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "transfer",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function"
    }
]

# Cell 7.5: Liquidity Pool ABI
LIQUIDITY_POOL_ABI = [
    {
        "type": "function",
        "name": "swap",
        "inputs": [
            {"name": "amount0In", "type": "uint256", "internalType": "uint256"},
            {"name": "amount1In", "type": "uint256", "internalType": "uint256"},
            {"name": "minAmountOut", "type": "uint256", "internalType": "uint256"}
        ],
        "outputs": [],
        "stateMutability": "nonpayable"
    },
    {
        "type": "function",
        "name": "getAmountOut",
        "inputs": [
            {"name": "amountIn", "type": "uint256", "internalType": "uint256"},
            {"name": "reserveIn", "type": "uint256", "internalType": "uint256"},
            {"name": "reserveOut", "type": "uint256", "internalType": "uint256"}
        ],
        "outputs": [
            {"name": "amountOut", "type": "uint256", "internalType": "uint256"}
        ],
        "stateMutability": "pure"
    },
    {
        "type": "function",
        "name": "getReserves",
        "inputs": [],
        "outputs": [
            {"name": "_reserve0", "type": "uint256", "internalType": "uint256"},
            {"name": "_reserve1", "type": "uint256", "internalType": "uint256"}
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "token0",
        "inputs": [],
        "outputs": [
            {"name": "", "type": "address", "internalType": "contract BasicERC20"}
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "token1",
        "inputs": [],
        "outputs": [
            {"name": "", "type": "address", "internalType": "contract BasicERC20"}
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "reserve0",
        "inputs": [],
        "outputs": [
            {"name": "", "type": "uint256", "internalType": "uint256"}
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "reserve1",
        "inputs": [],
        "outputs": [
            {"name": "", "type": "uint256", "internalType": "uint256"}
        ],
        "stateMutability": "view"
    }
]

# Cell 8: Initialize LLM
llm = ChatGoogleGenerativeAI(model="gemini-2.5-pro")

# Cell 9: Logging Setup
logger = logging.getLogger("defiops_agent")
logger.setLevel(logging.INFO)

# Clear existing handlers
if logger.handlers:
    logger.handlers.clear()

# Console handler
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
console_handler.setFormatter(formatter)
logger.addHandler(console_handler)

# Cell 10: State Definition
class AgentState(TypedDict):
    user_id: str
    user_wallet: str
    user_input: str
    intent: Optional[Dict[str, Any]]
    price_usd: Optional[float]
    quote: Optional[Dict[str, Any]]
    confirmation_required: bool
    user_approved: Optional[bool]
    execution_tx_hash: Optional[str]
    status: str
    error: Optional[str]
    memory: Dict[str, Any]
    llm_log: List[Dict[str, Any]]
    swap_transaction: Optional[Dict[str, Any]]

# Cell 11: Intent Schema
class Info(BaseModel):
    """
    Structured intent for a simple swap action.
    """
    action: str = Field(description="Action to perform: 'swap', 'buy' or 'sell'")
    asset_in: str = Field(description="Source token symbol or contract address")
    asset_out: str = Field(description="Destination token symbol or contract address")
    amount: float = Field(gt=0, description="Amount of asset_in to swap")
# Cell 12: Helper Functions
getcontext().prec = 60

def resolve_amount_to_base(amount: "float|str|Decimal", decimals: int) -> int:
    """Convert human amount to integer base units using Decimal."""
    if decimals < 0:
        raise ValueError("decimals must be non-negative")
    
    if isinstance(amount, Decimal):
        dec_amt = amount
    else:
        try:
            dec_amt = Decimal(str(amount))
        except (InvalidOperation, TypeError) as e:
            raise ValueError(f"Invalid amount: {amount}") from e

    if dec_amt <= 0:
        raise ValueError("amount must be > 0")

    scale = Decimal(10) ** Decimal(decimals)
    base = (dec_amt * scale).to_integral_value(rounding="ROUND_DOWN")
    return int(base)

def get_token_balance(token_address: str, holder_address: str) -> float:
    """Get token balance for an address"""
    token = w3.eth.contract(address=token_address, abi=ERC20_ABI)
    balance = token.functions.balanceOf(holder_address).call()
    decimals = token.functions.decimals().call()
    return balance / (10 ** decimals)

# Cell 12.5: Faucet Helper
def mint_test_tokens(wallet_address: str, amount_dash: float = 1000, amount_sms: float = 1000):
    """Mint test tokens to a wallet address (only works if you have minting rights)"""
    logger.info(f"\n{'='*60}")
    logger.info(f"MINTING TEST TOKENS")
    logger.info(f"{'='*60}")
    
    private_key = os.getenv("PRIVATE_KEY")
    if not private_key:
        logger.error("❌ Private key not configured")
        return False
    
    account = w3.eth.account.from_key(private_key)
    
    try:
        # Mint DASH tokens
        dash_contract = w3.eth.contract(address=DASH_TOKEN, abi=ERC20_ABI)
        dash_amount_base = resolve_amount_to_base(amount_dash, 18)
        
        # Check if there's a mint function (you may need to add this to your contract)
        # For now, if you're the deployer, transfer from your address
        
        logger.info(f"Attempting to get {amount_dash} DASH for {wallet_address}")
        
        # Check deployer's DASH balance
        deployer_dash = get_token_balance(DASH_TOKEN, DEPLOYER_ADDRESS)
        logger.info(f"Deployer DASH balance: {deployer_dash:.2f}")
        
        if deployer_dash >= amount_dash:
            # Transfer from deployer
            nonce = w3.eth.get_transaction_count(account.address)
            
            transfer_tx = dash_contract.functions.transfer(
                wallet_address,
                dash_amount_base
            ).build_transaction({
                'from': account.address,
                'gas': 100000,
                'gasPrice': w3.eth.gas_price,
                'nonce': nonce,
                'chainId': CHAIN_ID
            })
            
            signed_tx = account.sign_transaction(transfer_tx)
            tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
            
            if receipt['status'] == 1:
                logger.info(f"✓ Transferred {amount_dash} DASH to {wallet_address}")
                speak_text(f"Transferred {amount_dash} DASH")
            else:
                logger.error("❌ DASH transfer failed")
                return False
        
        # Mint SMS tokens (same logic)
        sms_contract = w3.eth.contract(address=SMS_TOKEN, abi=ERC20_ABI)
        sms_amount_base = resolve_amount_to_base(amount_sms, 18)
        
        deployer_sms = get_token_balance(SMS_TOKEN, DEPLOYER_ADDRESS)
        logger.info(f"Deployer SMS balance: {deployer_sms:.2f}")
        
        if deployer_sms >= amount_sms:
            nonce = w3.eth.get_transaction_count(account.address)
            
            transfer_tx = sms_contract.functions.transfer(
                wallet_address,
                sms_amount_base
            ).build_transaction({
                'from': account.address,
                'gas': 100000,
                'gasPrice': w3.eth.gas_price,
                'nonce': nonce,
                'chainId': CHAIN_ID
            })
            
            signed_tx = account.sign_transaction(transfer_tx)
            tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
            
            if receipt['status'] == 1:
                logger.info(f"✓ Transferred {amount_sms} SMS to {wallet_address}")
                speak_text(f"Transferred {amount_sms} SMS")
                return True
            else:
                logger.error("❌ SMS transfer failed")
                return False
        
        return True
        
    except Exception as e:
        logger.error(f"❌ Minting failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        return False

# Cell 13: Node 1 - Intent Interpretation (FIXED)
def node_interpret_intent(state: AgentState) -> AgentState:
    """Parse user input into structured intent using LLM"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 1: INTERPRET INTENT")
    speak_text("NODE 1: INTERPRET INTENT")
    logger.info(f"{'='*60}")
    logger.info(f"User input: {state['user_input']}")
    speak_text(f"User input: {state['user_input']}")
    
    system_prompt = (
        "You are a helper that MUST output strictly valid JSON matching this schema: "
        "{action, asset_in, asset_out, amount}. "
        "Fields:\n"
        "- action: one of \"swap\", \"buy\", \"sell\"\n"
        "- asset_in: token symbol or contract address\n"
        "- asset_out: token symbol or contract address\n"
        "- amount: numeric (float), positive\n\n"
        "Return only the JSON object."
    )

    examples = [
        {"user": "Swap $200 of USDC to ETH", "assistant": {"action":"swap","asset_in":"USDC","asset_out":"ETH","amount":200}},
        {"user": "buy 0.1 ETH with USDC", "assistant": {"action":"buy","asset_in":"USDC","asset_out":"ETH","amount":0.1}},
        {"user": "sell 10 DAI for USDC", "assistant": {"action":"sell","asset_in":"DAI","asset_out":"USDC","amount":10}}
    ]

    messages = [("system", system_prompt)]
    for ex in examples:
        messages.append(("user", ex["user"]))
        messages.append(("assistant", json.dumps(ex["assistant"])))
        
    resp = llm.invoke(messages+[("user", state["user_input"])])
    
    try:
        parsed = json.loads(resp.content)
        logger.info(f"LLM raw response: {parsed}")
    except Exception as e:
        logger.error(f"Could not parse JSON from LLM: {e}")
        state["error"] = "Could not parse JSON from LLM"
        state["status"] = "failed"
        return state  # ✅ FIX: Return state, not dict

    try:
        info = Info.model_validate(parsed)
        logger.info(f"✓ Intent parsed successfully:")
        logger.info(f"  Action: {info.action}")
        logger.info(f"  Asset In: {info.asset_in}")
        logger.info(f"  Asset Out: {info.asset_out}")
        logger.info(f"  Amount: {info.amount}")
        speak_text(f"Intent parsed successfully:")
        speak_text(f"Action: {info.action}")
        speak_text(f"Asset In: {info.asset_in}")
        speak_text(f"Asset Out: {info.asset_out}")
        speak_text(f"Amount: {info.amount}")
    except ValidationError as e:
        logger.error(f"Validation failed: {e}")
        state["error"] = f"Validation failed: {e}"
        state["status"] = "failed"
        return state  # ✅ FIX: Return state, not dict

    # ✅ FIX: Update state directly
    state["intent"] = info.model_dump()
    state["status"] = "intent_parsed"
    return state  # Return the modified state


# Cell 14: Node 2 - Price Fetch
SYMBOL_TO_ID = {
    "ETH": "ethereum",
    "BTC": "bitcoin",
    "WETH": "weth",
    "UNI": "uniswap",
    "USDC": "usd-coin",
    "MATIC": "matic-network",
    "BNB": "binancecoin",
    "SOL": "solana",
    "DAI": "dai"
}

def get_price_usd(token_symbol: str) -> float:
    token_symbol = token_symbol.upper()
    token_id = SYMBOL_TO_ID.get(token_symbol)

    if token_id is None:
        all_coins = requests.get(f"{COINGECKO_API_URL}/coins/list", timeout=10).json()
        for c in all_coins:
            if c["symbol"].lower() == token_symbol.lower():
                token_id = c["id"]
                SYMBOL_TO_ID[token_symbol] = token_id
                break
        if token_id is None:
            raise ValueError(f"Token symbol '{token_symbol}' not found on CoinGecko")

    params = {"ids": token_id, "vs_currencies": "usd"}
    headers = {"x-cg-demo-api-key": COINGECKO_API_KEY}
    resp = requests.get(f"{COINGECKO_API_URL}/simple/price", 
                       params=params, headers=headers, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    return float(data[token_id]["usd"])

# Cell 14: Node 2 - Price Fetch (FIXED)
def node_price_fetch(state: AgentState) -> AgentState:
    """Fetch USD price for the asset"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 2: PRICE FETCH")
    speak_text(f"NODE 2: PRICE FETCH")
    logger.info(f"{'='*60}")
    
    asset = state["intent"]["asset_in"]
    logger.info(f"Fetching price for: {asset}")
    speak_text(f"Fetching price for: {asset}")
    
    try:
        price = get_price_usd(asset)
        total_usd = price * float(state["intent"]["amount"])
        
        logger.info(f"✓ Price fetched:")
        logger.info(f"  {asset} price: ${price:,.2f}")
        logger.info(f"  Total value: ${total_usd:,.2f}")
        speak_text("Price fetched:")
        speak_text(f"{asset} price: ${price:,.2f}")
        speak_text(f"Total value: ${total_usd:,.2f}")
        
        # ✅ FIX: Update state directly
        state["price_usd"] = total_usd
        state["memory"]["price_usd"] = total_usd
        state["memory"]["token_price"] = price
        return state  # Return the modified state
    except Exception as e:
        logger.error(f"Price fetch failed: {e}")
        state["error"] = f"Price fetch failed: {e}"
        state["status"] = "failed"
        return state

# Cell 15: Node 3 - Quote Fetch (CORRECTED)
def node_quote_fetch(state: AgentState) -> AgentState:
    """Get swap quote from liquidity pool"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 3: QUOTE FETCH")
    speak_text("NODE 3: QUOTE FETCH")
    logger.info(f"{'='*60}")
    
    try:
        intent = state.get("intent")
        if not intent:
            state["status"] = "failed"
            state["error"] = "missing intent"
            return state

        a_in = intent.get("asset_in")
        a_out = intent.get("asset_out")
        amount = float(intent.get("amount", 0))

        if a_in not in TOKEN_MAP or a_out not in TOKEN_MAP:
            state["status"] = "failed"
            state["error"] = f"unsupported token symbol: {a_in} or {a_out}"
            return state

        from_token = TOKEN_MAP[a_in]
        to_token = TOKEN_MAP[a_out]
        amount_base = resolve_amount_to_base(amount, from_token["decimals"])
        
        logger.info(f"Quote parameters:")
        logger.info(f"  From: {a_in} ({from_token['address']})")
        logger.info(f"  To: {a_out} ({to_token['address']})")
        logger.info(f"  Amount: {amount} {a_in}")
        speak_text(f"Querying pool for quote")
        
        # Get pool contract
        pool_contract = w3.eth.contract(address=LIQUIDITY_POOL, abi=LIQUIDITY_POOL_ABI)
        
        # Determine which token is token0 and token1
        token0_addr = pool_contract.functions.token0().call()
        token1_addr = pool_contract.functions.token1().call()
        
        # Get reserves
        reserve0, reserve1 = pool_contract.functions.getReserves().call()
        
        logger.info(f"Pool info:")
        logger.info(f"  Token0: {token0_addr}")
        logger.info(f"  Token1: {token1_addr}")
        logger.info(f"  Reserve0: {reserve0}")
        logger.info(f"  Reserve1: {reserve1}")
        
        # Determine if we're swapping token0->token1 or token1->token0
        if from_token["address"].lower() == token0_addr.lower():
            # Swapping token0 for token1
            reserve_in = reserve0
            reserve_out = reserve1
            is_token0_to_token1 = True
        elif from_token["address"].lower() == token1_addr.lower():
            # Swapping token1 for token0
            reserve_in = reserve1
            reserve_out = reserve0
            is_token0_to_token1 = False
        else:
            state["status"] = "failed"
            state["error"] = f"Token {a_in} not found in pool"
            return state
        
        # Calculate expected output using the pool's formula
        amount_out_base = pool_contract.functions.getAmountOut(
            amount_base,
            reserve_in,
            reserve_out
        ).call()
        
        amount_out = amount_out_base / (10 ** to_token["decimals"])
        
        quote = {
            "fromToken": from_token,
            "toToken": to_token,
            "fromAmount": str(amount_base),
            "toAmount": str(amount_out_base),
            "estimatedGas": "150000",
            "pool": LIQUIDITY_POOL,
            "is_token0_to_token1": is_token0_to_token1,
            "reserve_in": reserve_in,
            "reserve_out": reserve_out
        }
        
        logger.info(f"✓ Quote from liquidity pool:")
        logger.info(f"  Input: {amount} {a_in}")
        logger.info(f"  Output: {amount_out:.6f} {a_out}")
        logger.info(f"  Rate: 1 {a_in} = {amount_out/amount:.6f} {a_out}")
        logger.info(f"  Direction: {'token0→token1' if is_token0_to_token1 else 'token1→token0'}")
        speak_text(f"Quote received: {amount_out:.6f} {a_out}")
        
        state["quote"] = quote
        state["status"] = "quote_ready"
        return state

    except Exception as e:
        logger.error(f"Quote fetch failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        state["status"] = "failed"
        state["error"] = str(e)
        return state

# Cell 16: Node 4 - Build Swap (CORRECTED)
def node_build_swap(state: AgentState) -> AgentState:
    """Build swap transaction for liquidity pool"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 4: BUILD SWAP")
    speak_text("NODE 4: BUILD SWAP")
    logger.info(f"{'='*60}")
    
    try:
        intent = state.get("intent")
        quote = state.get("quote")
        
        if not intent or not quote:
            state["status"] = "failed"
            state["error"] = "missing intent or quote"
            return state

        a_in = intent.get("asset_in")
        a_out = intent.get("asset_out")
        from_token = TOKEN_MAP[a_in]
        to_token = TOKEN_MAP[a_out]
        from_addr = state.get("user_wallet")
        
        if not from_addr:
            state["status"] = "failed"
            state["error"] = "missing user_wallet"
            return state
        
        amount_base = int(quote["fromAmount"])
        min_amount_out = int(int(quote["toAmount"]) * 0.98)  # 2% slippage tolerance
        is_token0_to_token1 = quote["is_token0_to_token1"]
        
        logger.info(f"Building swap transaction:")
        logger.info(f"  Pool: {LIQUIDITY_POOL}")
        logger.info(f"  From: {from_addr}")
        logger.info(f"  Direction: {'token0→token1' if is_token0_to_token1 else 'token1→token0'}")
        
        # Check balance
        current_balance = get_token_balance(from_token["address"], from_addr)
        required_amount = amount_base / (10 ** from_token["decimals"])
        
        if current_balance < required_amount:
            state["status"] = "failed"
            state["error"] = f"Insufficient balance: have {current_balance:.6f}, need {required_amount:.6f}"
            logger.error(f"❌ Insufficient balance: have {current_balance:.6f}, need {required_amount:.6f}")
            return state
        
        logger.info(f"✓ Sufficient balance: {current_balance:.6f} {a_in}")
        
        # Build approval transaction
        token_contract = w3.eth.contract(address=from_token["address"], abi=ERC20_ABI)
        
        # Get current nonce
        nonce = w3.eth.get_transaction_count(from_addr)
        
        approve_tx = token_contract.functions.approve(
            LIQUIDITY_POOL,
            amount_base
        ).build_transaction({
            'from': from_addr,
            'gas': 100000,
            'gasPrice': w3.eth.gas_price,
            'nonce': nonce,
            'chainId': CHAIN_ID
        })
        
        logger.info(f"✓ Approval transaction built (nonce: {nonce})")
        
        # Build swap transaction
        # swap(amount0In, amount1In, minAmountOut)
        # If swapping token0→token1: amount0In = amount, amount1In = 0
        # If swapping token1→token0: amount0In = 0, amount1In = amount
        
        pool_contract = w3.eth.contract(address=LIQUIDITY_POOL, abi=LIQUIDITY_POOL_ABI)
        
        if is_token0_to_token1:
            # Swapping token0 for token1
            amount0_in = amount_base
            amount1_in = 0
        else:
            # Swapping token1 for token0
            amount0_in = 0
            amount1_in = amount_base
        
        swap_tx = pool_contract.functions.swap(
            amount0_in,
            amount1_in,
            min_amount_out
        ).build_transaction({
            'from': from_addr,
            'gas': 200000,
            'gasPrice': w3.eth.gas_price,
            'nonce': nonce + 1,  # Incremented nonce
            'chainId': CHAIN_ID,
            'value': 0
        })
        
        logger.info(f"✓ Swap transaction built:")
        logger.info(f"  amount0In: {amount0_in}")
        logger.info(f"  amount1In: {amount1_in}")
        logger.info(f"  minAmountOut: {min_amount_out}")
        logger.info(f"  Gas estimate: {swap_tx['gas']}")
        logger.info(f"  Nonce: {nonce + 1}")
        speak_text("Swap transaction ready")
        
        state["swap_transaction"] = {
            "approval_tx": approve_tx,
            "swap_tx": swap_tx,
            "pool": LIQUIDITY_POOL
        }
        
        state["status"] = "swap_ready"
        return state

    except Exception as e:
        logger.error(f"Build swap failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        state["status"] = "failed"
        state["error"] = str(e)
        return state

def node_decide(state: AgentState) -> AgentState:
    """Determine if human confirmation needed based on risk"""
    total_usd = state["price_usd"]
    
    # Risk thresholds
    if total_usd > 100:
        state["confirmation_required"] = True
        logger.info(f"⚠️ High value swap (${total_usd:,.2f}) - requires confirmation")
        speak_text(f"High value swap (${total_usd:,.2f}) - requires confirmation")
    else:
        state["confirmation_required"] = False
        logger.info(f"✓ Auto-approve (${total_usd:,.2f} below threshold)")
        speak_text(f"Auto-approve (${total_usd:,.2f} below threshold)")
    
    return state

def node_human_confirm(state: AgentState) -> AgentState:
    logger.info("\n" + "="*60)
    logger.info("NODE 6: HUMAN CONFIRMATION")
    logger.info("="*60)

    intent = state.get("intent", {})
    amount = intent.get("amount")
    asset_in = intent.get("asset_in")
    asset_out = intent.get("asset_out")

    logger.info(f"Swap: {amount} {asset_in} → {asset_out}")
    logger.info(f"Value: ${state.get('price_usd', 0):.2f}")
    speak_text(f"Swap: {amount} {asset_in} → {asset_out}")
    speak_text(f"Value: ${state.get('price_usd', 0):.2f}")

    user_input = input("Approve? (yes/no): ").strip().lower()
    speak_text(f"User said {user_input}")
    state["user_approved"] = (user_input == "yes")
    return state

def node_execute_swap(state: AgentState) -> AgentState:
    """Execute the swap transaction on Sepolia"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 7: EXECUTE SWAP")
    logger.info(f"{'='*60}")
    
    if state.get("confirmation_required") and not state.get("user_approved"):
        logger.warning("❌ User rejected swap")
        state["status"] = "rejected"
        return state
    
    if "swap_transaction" not in state or not state["swap_transaction"]:
        logger.error("❌ No swap_transaction found")
        state["status"] = "failed"
        state["error"] = "No swap transaction object available"
        return state
    
    swap_tx = state["swap_transaction"]
    
    # YOU NEED TO ADD PRIVATE KEY HANDLING HERE
    private_key = os.getenv("PRIVATE_KEY")  # Add to .env
    if not private_key:
        logger.error("❌ Private key not configured")
        state["status"] = "failed"
        state["error"] = "Private key missing"
        return state
    
    account = w3.eth.account.from_key(private_key)
    
    try:
        # Step 1: Execute approval
        logger.info("Step 1: Approving tokens...")
        speak_text("Approving tokens")
        
        signed_approval = account.sign_transaction(swap_tx["approval_tx"])
        approval_hash = w3.eth.send_raw_transaction(signed_approval.raw_transaction)
        logger.info(f"Approval tx sent: {approval_hash.hex()}")
        
        approval_receipt = w3.eth.wait_for_transaction_receipt(approval_hash, timeout=120)
        if approval_receipt["status"] != 1:
            raise Exception("Approval transaction failed")
        
        logger.info(f"✓ Approval confirmed")
        speak_text("Approval confirmed")
        
        # Step 2: Execute swap
        logger.info("Step 2: Executing swap...")
        speak_text("Executing swap")
        
        signed_swap = account.sign_transaction(swap_tx["swap_tx"])
        swap_hash = w3.eth.send_raw_transaction(signed_swap.raw_transaction)
        logger.info(f"✓ Swap submitted: {swap_hash.hex()}")
        speak_text("Swap submitted")
        
        state["execution_tx_hash"] = swap_hash.hex()
        state["status"] = "executed"
        return state
        
    except Exception as e:
        logger.error(f"❌ Execution failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        state["status"] = "failed"
        state["error"] = f"Execution failed: {e}"
        return state

def node_monitor_tx(state: AgentState) -> AgentState:
    """Monitor transaction until confirmed"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 8: MONITOR TRANSACTION")
    logger.info(f"{'='*60}")
    
    tx_hash = state["execution_tx_hash"]
    logger.info(f"Monitoring tx: {tx_hash}")
    
    try:
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        
        if receipt["status"] == 1:
            logger.info(f"✓ Transaction CONFIRMED")
            logger.info(f"  Block: {receipt['blockNumber']}")
            logger.info(f"  Gas used: {receipt['gasUsed']:,}")
            speak_text("Transaction CONFIRMED")
            speak_text(f"Block: {receipt['blockNumber']}")
            speak_text(f"Gas used: {receipt['gasUsed']:,}")
            
            # Check final balances
            intent = state["intent"]
            from_token = TOKEN_MAP[intent["asset_in"]]
            to_token = TOKEN_MAP[intent["asset_out"]]
            from_addr = state["user_wallet"]
            
            final_balance_out = get_token_balance(to_token["address"], from_addr)
            logger.info(f"  New {intent['asset_out']} balance: {final_balance_out:.6f}")
            
            state["status"] = "completed"
            state["memory"]["final_balance"] = final_balance_out
        else:
            logger.error("❌ Transaction FAILED")
            state["status"] = "failed"
            state["error"] = "Transaction reverted"
    
    except Exception as e:
        logger.error(f"❌ Monitoring failed: {e}")
        state["status"] = "failed"
        state["error"] = str(e)
    
    return state

# Cell 17: Build Graph
graph = StateGraph(AgentState)
graph.add_node("INTERPRET_INTENT", node_interpret_intent)
graph.add_node("PRICE_FETCH", node_price_fetch)
graph.add_node("QUOTE_FETCH", node_quote_fetch)
graph.add_node("BUILD_SWAP", node_build_swap)
graph.add_node("DECIDE", node_decide)
graph.add_node("HUMAN_CONFIRM", node_human_confirm)
graph.add_node("EXECUTE",node_execute_swap)
graph.add_node("MONITOR",node_monitor_tx)

graph.set_entry_point("INTERPRET_INTENT")
graph.set_finish_point("MONITOR")

graph.add_edge("INTERPRET_INTENT", "PRICE_FETCH")
graph.add_edge("PRICE_FETCH", "QUOTE_FETCH")
graph.add_edge("QUOTE_FETCH", "BUILD_SWAP")
graph.add_edge("BUILD_SWAP", "DECIDE")
graph.add_conditional_edges(
    "DECIDE",
    lambda state: "HUMAN_CONFIRM" if state["confirmation_required"] else "EXECUTE",
    {
        "HUMAN_CONFIRM": "HUMAN_CONFIRM",
        "EXECUTE": "EXECUTE"
    }
)
graph.add_edge("HUMAN_CONFIRM","EXECUTE")
graph.add_edge("EXECUTE","MONITOR")

app = graph.compile()

# Cell 18: Visualize Graph
print(display(Image(app.get_graph().draw_mermaid_png())))
# Cell 19: Test Execution
print("\n" + "="*80)
print("DEFI-OPS AGENT - SEPOLIA TESTNET")
print("="*80)

# Use your wallet address (the one with the private key)
private_key = os.getenv("PRIVATE_KEY")
if not private_key:
    raise ValueError("PRIVATE_KEY not found in .env")

account = w3.eth.account.from_key(private_key)
test_wallet = account.address

logger.info(f"Using wallet: {test_wallet}")
logger.info(f"Deployer address: {DEPLOYER_ADDRESS}")

# Check if wallet needs funding
dash_balance = get_token_balance(DASH_TOKEN, test_wallet)
sms_balance = get_token_balance(SMS_TOKEN, test_wallet)
eth_balance = w3.eth.get_balance(test_wallet) / 10**18

logger.info(f"\nCurrent Balances:")
logger.info(f"  ETH: {eth_balance:.4f}")
logger.info(f"  DASH: {dash_balance:.2f}")
logger.info(f"  SMS: {sms_balance:.2f}")

# Fund wallet if needed
if dash_balance < 100 or sms_balance < 100:
    logger.info(f"\n⚠️  Wallet needs tokens!")
    logger.info(f"Attempting to transfer from deployer...")
    
    if test_wallet.lower() == DEPLOYER_ADDRESS.lower():
        logger.info("✓ Using deployer address, tokens should already be available")
    else:
        # Transfer tokens from deployer to test wallet
        mint_test_tokens(test_wallet, amount_dash=500, amount_sms=500)
        
        # Recheck balances
        dash_balance = get_token_balance(DASH_TOKEN, test_wallet)
        sms_balance = get_token_balance(SMS_TOKEN, test_wallet)
        logger.info(f"\nUpdated Balances:")
        logger.info(f"  DASH: {dash_balance:.2f}")
        logger.info(f"  SMS: {sms_balance:.2f}")

if eth_balance < 0.01:
    logger.warning(f"\n⚠️  Low ETH balance: {eth_balance:.4f} ETH")
    logger.warning(f"Get Sepolia ETH from: https://sepoliafaucet.com/")
    logger.warning(f"Or: https://www.alchemy.com/faucets/ethereum-sepolia")
    input("Press Enter after getting Sepolia ETH...")

# Now run the agent
user_input = whisper_transcribe(duration=7) 

initial_state: AgentState = {
    "user_id": "user1",
    "user_wallet": test_wallet,
    "user_input": user_input,
    "intent": None,
    "price_usd": None,
    "quote": None,
    "confirmation_required": False,
    "user_approved": None,
    "execution_tx_hash": None,
    "status": "initialized",
    "error": None,
    "memory": {},
    "llm_log": [],
    "swap_transaction": None
}

logger.info(f"\nStarting agent...")
logger.info(f"Input: {user_input}")
speak_text(f"Starting swap agent")

result = app.invoke(initial_state)

print("\n" + "="*80)
print("FINAL RESULT")
print("="*80)
print(f"Status: {result['status']}")

if result.get('error'):
    print(f"Error: {result['error']}")
    speak_text(f"Error: {result['error']}")
else:
    print(f"✓ Agent completed successfully!")
    speak_text("Agent completed successfully!")
    
    print(f"\nIntent: {result['intent']}")
    print(f"Price USD: ${result.get('price_usd', 0):,.2f}")
    
    if result.get('execution_tx_hash'):
        print(f"\n✅ Transaction Hash: {result['execution_tx_hash']}")
        print(f"View on Etherscan: https://sepolia.etherscan.io/tx/{result['execution_tx_hash']}")
        speak_text("Transaction successful! Check Etherscan")
        
        # Show final balances
        dash_final = get_token_balance(DASH_TOKEN, test_wallet)
        sms_final = get_token_balance(SMS_TOKEN, test_wallet)
        print(f"\nFinal Balances:")
        print(f"  DASH: {dash_final:.2f}")
        print(f"  SMS: {sms_final:.2f}")