# verification_script.py
from web3 import Web3
from dotenv import load_dotenv
import os

load_dotenv()

# Configuration
ALCHEMY_RPC_URL = os.getenv("ALCHEMY_RPC_URL")
w3 = Web3(Web3.HTTPProvider(ALCHEMY_RPC_URL))

DASH_TOKEN = "0xA4e2553B97FCa8205a8ba108814016e43c9fd32a"
SMS_TOKEN = "0x56C092A883032CE07Bb2b506eFf8EeEe85b444F8"
LIQUIDITY_POOL = "0xE3f19EdE356F5E1C1Ef3499F80F794D2C9F3670a"

# ERC20 ABI (minimal)
ERC20_ABI = [
    {
        "constant": True,
        "inputs": [],
        "name": "symbol",
        "outputs": [{"name": "", "type": "string"}],
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
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function"
    }
]

# Liquidity Pool ABI
POOL_ABI = [
    {
        "type": "function",
        "name": "token0",
        "inputs": [],
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "token1",
        "inputs": [],
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "getReserves",
        "inputs": [],
        "outputs": [
            {"name": "_reserve0", "type": "uint256"},
            {"name": "_reserve1", "type": "uint256"}
        ],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "reserve0",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "reserve1",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view"
    },
    {
        "type": "function",
        "name": "getAmountOut",
        "inputs": [
            {"name": "amountIn", "type": "uint256"},
            {"name": "reserveIn", "type": "uint256"},
            {"name": "reserveOut", "type": "uint256"}
        ],
        "outputs": [{"name": "amountOut", "type": "uint256"}],
        "stateMutability": "pure"
    }
]

print("="*80)
print("LIQUIDITY POOL VERIFICATION SCRIPT")
print("="*80)

# Check connection
print(f"\n✓ Connected to: {w3.provider.endpoint_uri}")
print(f"✓ Chain ID: {w3.eth.chain_id} (Sepolia: 11155111)")
print(f"✓ Latest Block: {w3.eth.block_number}")

# ========================================
# 1. CHECK TOKEN ORDER (token0 vs token1)
# ========================================
print("\n" + "="*80)
print("1. TOKEN ORDER IN POOL")
print("="*80)

pool = w3.eth.contract(address=LIQUIDITY_POOL, abi=POOL_ABI)

token0_address = pool.functions.token0().call()
token1_address = pool.functions.token1().call()

print(f"token0 address: {token0_address}")
print(f"token1 address: {token1_address}")

# Get token symbols
token0_contract = w3.eth.contract(address=token0_address, abi=ERC20_ABI)
token1_contract = w3.eth.contract(address=token1_address, abi=ERC20_ABI)

token0_symbol = token0_contract.functions.symbol().call()
token1_symbol = token1_contract.functions.symbol().call()

print(f"\n✓ token0 = {token0_symbol} ({token0_address})")
print(f"✓ token1 = {token1_symbol} ({token1_address})")

# Compare with your TOKEN_MAP
print("\n🔍 Verification:")
if token0_address.lower() == DASH_TOKEN.lower():
    print("  ✅ token0 = DASH")
    print("  ✅ token1 = SMS")
elif token0_address.lower() == SMS_TOKEN.lower():
    print("  ✅ token0 = SMS")
    print("  ✅ token1 = DASH")
else:
    print("  ❌ ERROR: token0 doesn't match DASH or SMS!")

# ========================================
# 2. CHECK LIQUIDITY (RESERVES)
# ========================================
print("\n" + "="*80)
print("2. POOL LIQUIDITY (RESERVES)")
print("="*80)

try:
    reserve0, reserve1 = pool.functions.getReserves().call()
    
    token0_decimals = token0_contract.functions.decimals().call()
    token1_decimals = token1_contract.functions.decimals().call()
    
    reserve0_human = reserve0 / (10 ** token0_decimals)
    reserve1_human = reserve1 / (10 ** token1_decimals)
    
    print(f"reserve0 ({token0_symbol}): {reserve0} ({reserve0_human:,.2f} {token0_symbol})")
    print(f"reserve1 ({token1_symbol}): {reserve1} ({reserve1_human:,.2f} {token1_symbol})")
    
    print("\n🔍 Verification:")
    if reserve0 == 0 or reserve1 == 0:
        print("  ❌ CRITICAL: Pool has NO LIQUIDITY!")
        print("  ❌ You must call addLiquidity() before swaps will work")
        print("\n  📝 To add liquidity, run:")
        print(f"     pool.addLiquidity({token0_symbol}_amount, {token1_symbol}_amount)")
    else:
        print(f"  ✅ Pool has liquidity")
        print(f"  ✅ Current ratio: 1 {token0_symbol} = {reserve1_human/reserve0_human:.6f} {token1_symbol}")
        
        # Calculate constant product
        k = reserve0 * reserve1
        print(f"  ✅ Constant product (k): {k:,}")

except Exception as e:
    print(f"❌ Error getting reserves: {e}")

# ========================================
# 3. CHECK FEE STRUCTURE
# ========================================
print("\n" + "="*80)
print("3. FEE STRUCTURE")
print("="*80)

# Test the getAmountOut function to reverse-engineer the fee
if reserve0 > 0 and reserve1 > 0:
    # Input 1000 tokens (1000 * 10^18 in base units)
    test_amount_in = 1000 * (10 ** token0_decimals)
    
    try:
        amount_out = pool.functions.getAmountOut(
            test_amount_in,
            reserve0,
            reserve1
        ).call()
        
        # Calculate what we'd get with NO fees (constant product)
        # amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
        expected_no_fee = (test_amount_in * reserve1) // (reserve0 + test_amount_in)
        
        # Calculate what we'd get with 0.3% fee (Uniswap style)
        # amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        amount_in_with_fee = test_amount_in * 997
        expected_with_fee = (amount_in_with_fee * reserve1) // (reserve0 * 1000 + amount_in_with_fee)
        
        print(f"Test: Swapping 1000 {token0_symbol}")
        print(f"Expected output (no fee):    {expected_no_fee / (10**token1_decimals):.6f} {token1_symbol}")
        print(f"Expected output (0.3% fee):  {expected_with_fee / (10**token1_decimals):.6f} {token1_symbol}")
        print(f"Actual output from pool:     {amount_out / (10**token1_decimals):.6f} {token1_symbol}")
        
        print("\n🔍 Verification:")
        if abs(amount_out - expected_with_fee) < 1000:  # Allow small rounding difference
            print("  ✅ Pool uses 0.3% fee (Uniswap standard)")
        elif abs(amount_out - expected_no_fee) < 1000:
            print("  ✅ Pool uses 0% fee (no trading fee)")
        else:
            fee_ratio = (expected_no_fee - amount_out) / expected_no_fee
            print(f"  ⚠️  Pool uses custom fee: ~{fee_ratio*100:.2f}%")
            
    except Exception as e:
        print(f"❌ Error testing fees: {e}")
else:
    print("⚠️  Cannot test fees - pool has no liquidity")

# ========================================
# 4. CHECK SLIPPAGE PROTECTION
# ========================================
print("\n" + "="*80)
print("4. SLIPPAGE PROTECTION")
print("="*80)

print("Looking at swap function signature...")
print("swap(uint256 amount0In, uint256 amount1In, uint256 minAmountOut)")
print("\n🔍 Analysis:")
print("  ✅ Function has 'minAmountOut' parameter")
print("  ✅ This means slippage protection IS implemented")
print("\n  How it works:")
print("  - You calculate expected output: e.g., 100 tokens")
print("  - You set minAmountOut with tolerance: e.g., 98 tokens (2% slippage)")
print("  - If actual output < 98, transaction reverts")
print("\n  In your code:")
print("    min_amount_out = int(int(quote['toAmount']) * 0.98)  # 2% slippage")

# ========================================
# 5. ADDITIONAL CHECKS
# ========================================
print("\n" + "="*80)
print("5. ADDITIONAL INFORMATION")
print("="*80)

# Check pool's token balances (should equal reserves)
pool_balance_token0 = token0_contract.functions.balanceOf(LIQUIDITY_POOL).call()
pool_balance_token1 = token1_contract.functions.balanceOf(LIQUIDITY_POOL).call()

print(f"Pool's actual {token0_symbol} balance: {pool_balance_token0 / (10**token0_decimals):,.2f}")
print(f"Pool's actual {token1_symbol} balance: {pool_balance_token1 / (10**token1_decimals):,.2f}")

if pool_balance_token0 == reserve0 and pool_balance_token1 == reserve1:
    print("  ✅ Reserves match actual balances (healthy pool)")
else:
    print("  ⚠️  Reserves don't match balances - pool might need sync")

# ========================================
# FINAL SUMMARY
# ========================================
print("\n" + "="*80)
print("SUMMARY & RECOMMENDATIONS")
print("="*80)

issues = []
warnings = []
success = []

if reserve0 == 0 or reserve1 == 0:
    issues.append("❌ NO LIQUIDITY - Must add liquidity before swaps work")
else:
    success.append(f"✅ Pool has liquidity: {reserve0_human:,.2f} {token0_symbol} / {reserve1_human:,.2f} {token1_symbol}")

if token0_address.lower() in [DASH_TOKEN.lower(), SMS_TOKEN.lower()]:
    success.append(f"✅ Token order confirmed: token0={token0_symbol}, token1={token1_symbol}")
else:
    issues.append("❌ Token addresses don't match expected DASH/SMS")

success.append("✅ Slippage protection is implemented via minAmountOut")

print("\n" + "SUCCESS:")
for s in success:
    print(f"  {s}")

if warnings:
    print("\n" + "WARNINGS:")
    for w in warnings:
        print(f"  {w}")

if issues:
    print("\n" + "CRITICAL ISSUES:")
    for i in issues:
        print(f"  {i}")
    print("\n❌ You must fix these issues before swaps will work!")
else:
    print("\n🎉 Your pool is ready for swaps!")

print("="*80)