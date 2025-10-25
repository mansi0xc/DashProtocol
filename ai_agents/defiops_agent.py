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

warnings.filterwarnings("ignore", category=DeprecationWarning)

# Cell 2: Load Environment
load_dotenv()

# Cell 3: Load Token Map
with open("tokens_map.json") as f:
    TOKEN_MAP = json.load(f)

# Cell 4: Configuration
# Determine if we're in testing mode (fork) or production (mainnet)
IS_TESTING = os.getenv("IS_TESTING", "true").lower() == "true"

if IS_TESTING:
    # Tenderly Fork Configuration
    TENDERLY_RPC_URL = os.getenv('TENDERLY_RPC_URL')
    w3 = Web3(Web3.HTTPProvider(TENDERLY_RPC_URL))
    print(f"✓ Connected to Tenderly Fork")
else:
    # Mainnet Configuration
    ALCHEMY_RPC_URL = os.getenv("ALCHEMY_RPC_URL")
    w3 = Web3(Web3.HTTPProvider(ALCHEMY_RPC_URL))
    print(f"✓ Connected to Mainnet")

# Common Configuration
COINGECKO_API_URL = os.getenv("COINGECKO_API_URL")
COINGECKO_API_KEY = os.getenv("COINGECKO_API_KEY")
ONEINCH_API_KEY = os.getenv("ONEINCH_API_KEY")
CHAIN_ID = int(os.getenv("CHAIN_ID", "1"))

# 1inch URLs (only used in production)
ONEINCH_BASE_URL = f"https://api.1inch.dev/swap/v6.0/{CHAIN_ID}"
ONEINCH_QUOTE_URL = f"{ONEINCH_BASE_URL}/quote"
ONEINCH_SWAP_URL = f"{ONEINCH_BASE_URL}/swap"

# Uniswap Configuration (used in testing)
UNISWAP_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"

print(f"Connected: {w3.is_connected()}")
print(f"Chain ID: {w3.eth.chain_id}")
print(f"Latest Block: {w3.eth.block_number}")
print(f"Mode: {'TESTING (Fork)' if IS_TESTING else 'PRODUCTION (Mainnet)'}")

# Cell 5: Whale Addresses for Testing
WHALES = {
    'USDC': '0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503',  # Binance
    'USDT': '0x5754284f345afc66a98fbB0a0Afe71e0F007B949',  # Binance
    'DAI': '0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf',   # Polygon Bridge
    'WETH': '0x2F0b23f53734252Bda2277357e97e1517d6B042A',  # Gemini
}

# Cell 6: ERC20 ABI
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
            {"name": "_to", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "transfer",
        "outputs": [{"name": "", "type": "bool"}],
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
    }
]

# Cell 7: Uniswap Router ABI
UNISWAP_ROUTER_ABI = [{
    "inputs": [{
        "components": [
            {"internalType": "address", "name": "tokenIn", "type": "address"},
            {"internalType": "address", "name": "tokenOut", "type": "address"},
            {"internalType": "uint24", "name": "fee", "type": "uint24"},
            {"internalType": "address", "name": "recipient", "type": "address"},
            {"internalType": "uint256", "name": "deadline", "type": "uint256"},
            {"internalType": "uint256", "name": "amountIn", "type": "uint256"},
            {"internalType": "uint256", "name": "amountOutMinimum", "type": "uint256"},
            {"internalType": "uint160", "name": "sqrtPriceLimitX96", "type": "uint160"}
        ],
        "internalType": "struct ISwapRouter.ExactInputSingleParams",
        "name": "params",
        "type": "tuple"
    }],
    "name": "exactInputSingle",
    "outputs": [{"internalType": "uint256", "name": "amountOut", "type": "uint256"}],
    "stateMutability": "payable",
    "type": "function"
}]

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

def fund_account_with_eth(to_address: str, amount_eth: float):
    """Fund an address with ETH on Tenderly fork"""
    if not IS_TESTING:
        logger.warning("fund_account_with_eth called in production mode - skipping")
        return
    
    amount_wei = w3.to_wei(amount_eth, 'ether')
    amount_hex = hex(amount_wei)
    
    w3.provider.make_request("tenderly_setBalance", [to_address, amount_hex])
    logger.info(f"✓ Funded {to_address} with {amount_eth} ETH on fork")

# Cell 13: Node 1 - Intent Interpretation (FIXED)
def node_interpret_intent(state: AgentState) -> AgentState:
    """Parse user input into structured intent using LLM"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 1: INTERPRET INTENT")
    logger.info(f"{'='*60}")
    logger.info(f"User input: {state['user_input']}")
    
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
    logger.info(f"{'='*60}")
    
    asset = state["intent"]["asset_in"]
    logger.info(f"Fetching price for: {asset}")
    
    try:
        price = get_price_usd(asset)
        total_usd = price * float(state["intent"]["amount"])
        
        logger.info(f"✓ Price fetched:")
        logger.info(f"  {asset} price: ${price:,.2f}")
        logger.info(f"  Total value: ${total_usd:,.2f}")
        
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


# Cell 15: Node 3 - Quote (Fork-aware)
def node_quote_fetch(state: AgentState) -> AgentState:
    """Get swap quote - uses different methods for testing vs production"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 3: QUOTE FETCH")
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
        logger.info(f"  Amount: {amount} {a_in} ({amount_base} base units)")

        if IS_TESTING:
            # In testing mode, we simulate a quote based on current prices
            logger.info(f"⚠️  TESTING MODE: Simulating quote (Uniswap will be used for actual swap)")
            
            # Get approximate output based on current prices
            price_in = state["memory"].get("token_price", get_price_usd(a_in))
            price_out = get_price_usd(a_out)
            
            estimated_out_usd = amount * price_in
            estimated_out_tokens = estimated_out_usd / price_out
            estimated_out_base = int(estimated_out_tokens * (10 ** to_token["decimals"]))
            
            quote = {
                "toAmount": str(estimated_out_base),
                "fromToken": from_token,
                "toToken": to_token,
                "fromAmount": str(amount_base),
                "estimatedGas": "200000",
                "protocols": [["UNISWAP_V3"]],
                "testing_mode": True
            }
            
            logger.info(f"✓ Simulated quote:")
            logger.info(f"  Estimated output: {estimated_out_tokens:.6f} {a_out}")
            logger.info(f"  Rate: 1 {a_in} ≈ {estimated_out_tokens/amount:.6f} {a_out}")
            
        else:
            # Production mode - use 1inch API
            logger.info(f"PRODUCTION MODE: Fetching real quote from 1inch")
            from_addr = state.get("user_wallet")
            
            params = {
                "src": from_token["address"],
                "dst": to_token["address"],
                "amount": str(amount_base),
                "from": from_addr,
                "slippage": "1"
            }
            
            headers = {"Authorization": f"Bearer {ONEINCH_API_KEY}"}
            resp = requests.get(ONEINCH_QUOTE_URL, params=params, headers=headers, timeout=10)
            
            if not resp.ok:
                logger.error(f"1inch quote failed: {resp.status_code} - {resp.text[:500]}")
                resp.raise_for_status()
            
            quote = resp.json()
            output_amount = int(quote["toAmount"]) / (10 ** to_token["decimals"])
            logger.info(f"✓ Quote received from 1inch:")
            logger.info(f"  Output: {output_amount:.6f} {a_out}")

        state["quote"] = quote
        state["status"] = "quote_ready"
        return state

    except Exception as e:
        logger.error(f"Quote fetch failed: {e}")
        state["status"] = "failed"
        state["error"] = str(e)
        return state

# Cell 16: Node 4 - Build Swap (FIXED)
def node_build_swap(state: AgentState) -> AgentState:
    """Build swap transaction - uses Uniswap for testing, 1inch for production"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 4: BUILD SWAP")
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
        from_addr = state.get("user_wallet")
        
        if not from_addr:
            state["status"] = "failed"
            state["error"] = "missing user_wallet"
            return state

        if IS_TESTING:
            logger.info(f"⚠️  TESTING MODE: Building Uniswap V3 swap")
            
            # Setup whale address if needed
            if from_addr in WHALES.values():
                logger.info(f"Using whale address: {from_addr}")
            else:
                logger.info(f"Funding test address: {from_addr}")
                fund_account_with_eth(from_addr, 10)
            
            # Check and log balances
            initial_balance = get_token_balance(from_token["address"], from_addr)
            logger.info(f"Initial {a_in} balance: {initial_balance:.6f}")
            
            if initial_balance < amount:
                logger.warning(f"⚠️  Insufficient balance! Has {initial_balance}, needs {amount}")
                if a_in in WHALES:
                    whale_addr = WHALES[a_in]
                    fund_account_with_eth(whale_addr, 10)
                    
                    token_contract = w3.eth.contract(address=from_token["address"], abi=ERC20_ABI)
                    transfer_tx = token_contract.functions.transfer(
                        from_addr,
                        amount_base
                    ).build_transaction({
                        'from': whale_addr,
                        'gas': 100000,
                        'gasPrice': w3.eth.gas_price,
                        'nonce': w3.eth.get_transaction_count(whale_addr)
                    })
                    
                    tx_hash = w3.eth.send_transaction(transfer_tx)
                    w3.eth.wait_for_transaction_receipt(tx_hash)
                    logger.info(f"✓ Transferred {amount} {a_in} from whale to test address")
            
            # Approve Uniswap router
            logger.info(f"Approving Uniswap router...")
            token_contract = w3.eth.contract(address=from_token["address"], abi=ERC20_ABI)
            approve_tx = token_contract.functions.approve(
                UNISWAP_ROUTER,
                amount_base
            ).build_transaction({
                'from': from_addr,
                'gas': 100000,
                'gasPrice': w3.eth.gas_price,
                'nonce': w3.eth.get_transaction_count(from_addr)
            })
            
            logger.info(f"✓ Approval transaction built")
            
            # Build Uniswap swap transaction
            deadline = int(time.time()) + 300
            uniswap_router = w3.eth.contract(address=UNISWAP_ROUTER, abi=UNISWAP_ROUTER_ABI)
            
            swap_params = {
                'tokenIn': from_token["address"],
                'tokenOut': to_token["address"],
                'fee': 3000,
                'recipient': from_addr,
                'deadline': deadline,
                'amountIn': amount_base,
                'amountOutMinimum': 0,
                'sqrtPriceLimitX96': 0
            }
            
            swap_tx = uniswap_router.functions.exactInputSingle(
                swap_params
            ).build_transaction({
                'from': from_addr,
                'gas': 300000,
                'gasPrice': w3.eth.gas_price,
                'nonce': w3.eth.get_transaction_count(from_addr) + 1,
                'value': 0
            })
            
            logger.info(f"✓ Uniswap swap transaction built:")
            logger.info(f"  Router: {UNISWAP_ROUTER}")
            logger.info(f"  Gas estimate: {swap_tx['gas']}")
            
            # ✅ CRITICAL FIX: Store in state directly
            state["swap_transaction"] = {
                "approval_tx": approve_tx,
                "swap_tx": swap_tx,
                "router": UNISWAP_ROUTER,
                "testing_mode": True
            }
            
        else:
            logger.info(f"PRODUCTION MODE: Building 1inch swap")
            
            params = {
                "src": from_token["address"],
                "dst": to_token["address"],
                "amount": str(amount_base),
                "from": from_addr,
                "slippage": "1"
            }
            
            headers = {"Authorization": f"Bearer {ONEINCH_API_KEY}"}
            resp = requests.get(ONEINCH_SWAP_URL, params=params, headers=headers, timeout=15)
            
            if not resp.ok:
                logger.error(f"1inch swap failed: {resp.status_code} - {resp.text[:500]}")
                resp.raise_for_status()
            
            swap_resp = resp.json()
            tx_obj = swap_resp.get("tx") or swap_resp
            
            logger.info(f"✓ 1inch swap transaction built:")
            logger.info(f"  To: {tx_obj.get('to')}")
            logger.info(f"  Gas estimate: {tx_obj.get('gas')}")
            
            # ✅ CRITICAL FIX: Store in state directly
            state["swap_transaction"] = tx_obj

        # ✅ CRITICAL FIX: Update status in state
        state["status"] = "swap_ready"
        logger.info(f"\n✓ Swap transaction ready for execution")
        
        # ✅ Return the modified state object
        return state

    except Exception as e:
        logger.error(f"Build swap failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        state["status"] = "failed"
        state["error"] = str(e)
        logger.info(f"DEBUG: keys in state after build_swap: {list(state.keys())}")
        return state


def node_decide(state: AgentState) -> AgentState:
    """Determine if human confirmation needed based on risk"""
    total_usd = state["price_usd"]
    
    # Risk thresholds
    if total_usd > 100:
        state["confirmation_required"] = True
        logger.info(f"⚠️ High value swap (${total_usd:,.2f}) - requires confirmation")
    else:
        state["confirmation_required"] = False
        logger.info(f"✓ Auto-approve (${total_usd:,.2f} below threshold)")
    
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

    user_input = input("Approve? (yes/no): ").strip().lower()
    state["user_approved"] = (user_input == "yes")
    return state

def node_execute_swap(state: AgentState) -> AgentState:
    """Execute the swap transaction"""
    logger.info(f"\n{'='*60}")
    logger.info(f"NODE 7: EXECUTE SWAP")
    logger.info(f"{'='*60}")
    logger.info(f"DEBUG: keys in state before execution: {list(state.keys())}")
    
    # If confirmation was required and the user did not approve
    if state.get("confirmation_required") and not state.get("user_approved"):
        logger.warning("❌ User rejected swap")
        state["status"] = "rejected"
        return state
    
    # Ensure swap transaction object exists
    if "swap_transaction" not in state or not state["swap_transaction"]:
        logger.error("❌ No swap_transaction found in state. Build swap must run first.")
        state["status"] = "failed"
        state["error"] = "No swap transaction object available"
        return state
    
    swap_tx = state["swap_transaction"]
    
    if IS_TESTING:
        logger.info("Executing on Tenderly fork...")

        # If there is an approval step inside swap_tx
        if isinstance(swap_tx, dict) and "approval_tx" in swap_tx:
            try:
                logger.info("Step 1: Approving tokens...")
                approval_hash = w3.eth.send_transaction(swap_tx["approval_tx"])
                receipt = w3.eth.wait_for_transaction_receipt(approval_hash)
                logger.info(f"✓ Approval confirmed: {approval_hash.hex()}")
            except Exception as e:
                logger.error(f"❌ Approval transaction failed: {e}")
                state["status"] = "failed"
                state["error"] = f"Approval failed: {e}"
                return state

        # Execute the actual swap
        try:
            logger.info("Step 2: Executing swap...")
            swap_hash = w3.eth.send_transaction(swap_tx["swap_tx"])
            logger.info(f"✓ Swap submitted: {swap_hash.hex()}")
            state["execution_tx_hash"] = swap_hash.hex()
        except Exception as e:
            logger.error(f"❌ Swap transaction failed: {e}")
            state["status"] = "failed"
            state["error"] = f"Swap execution failed: {e}"
            return state

    else:
        logger.info("Executing on mainnet...")
        # (Here you would include the logic to sign & send using a private key)
        # Example: tx_hash = build_and_send_tx(swap_tx, private_key)
        # state["execution_tx_hash"] = tx_hash
        logger.warning("⚠️ Mainnet execution path not implemented")
        state["status"] = "failed"
        state["error"] = "Mainnet execution not configured"
        return state

    state["status"] = "executed"
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
print("DEFI-OPS AGENT TEST EXECUTION")
print("="*80)

# For testing, use a whale address
test_wallet = WHALES['WETH'] if IS_TESTING else "0xB8db1eF70b0d31c6eCE7695965791A45dE0f0035"

user_input = 'swap 0.1 WETH to UNI'
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
    "llm_log": []
}

logger.info(f"Starting agent with wallet: {test_wallet}")
logger.info(f"Input: {user_input}")

result = app.invoke(initial_state)

print("\n" + "="*80)
print("FINAL RESULT")
print("="*80)
print(f"Status: {result['status']}")
if result.get('error'):
    print(f"Error: {result['error']}")
else:
    print(f"✓ Agent completed successfully!")
    print(f"\nIntent: {result['intent']}")
    print(f"Price USD: ${result['price_usd']:,.2f}")
    if result.get('swap_transaction'):
        print(f"\nSwap transaction ready:")
        if IS_TESTING:
            print(f"  Mode: TESTING (Uniswap V3)")
            print(f"  Approval needed: Yes")
        else:
            print(f"  Mode: PRODUCTION (1inch)")
        print(f"  Ready for execution: Yes")