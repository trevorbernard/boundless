# Order Prioritization: HighestExpectedValue Strategy

## Overview

The **HighestExpectedValue** prioritization strategy maximizes expected profit
by accounting for both the revenue from an order and the costs required to
fulfill it, weighted by the probability of successfully completing the order.

I chose an expected value–based approach because it is simple to understand and
can be implemented in a straightforward way. At the same time, it provides a
flexible foundation: the strategy can be endlessly refined to address challenges
such as low- or high-contention markets, making it adaptable to a wide range of
scenarios.

## Formula

```
Expected Value = (Potential Profit) × P(success)
```

Where:
- **Potential Profit** = Revenue - Costs
- **P(success)** = Probability of successfully completing the order

## Component Breakdown

### 1. Revenue Calculation

```
Revenue = order.request.offer.maxPrice
```

The `maxPrice` represents the maximum amount the client is willing to pay in the
reverse Dutch auction. This is a conservative estimate since the actual payment
could be lower if the auction price has decreased.

**Future Enhancement:** Use current auction price instead of maxPrice for more
accurate revenue estimation.

### 2. Cost Calculation

```
Total Costs = Proving Costs + Gas Costs

where:
  Proving Costs = (total_cycles / 1,000,000) × mcycle_price

  Gas Costs = (lockin_gas_estimate × gas_price) +
              (fulfill_gas_estimate × gas_price) +
              (groth16_verify_gas_estimate × gas_price)
```

**Components:**
- **Proving Costs**: Computational cost based on RISC-V cycles required
- **Gas Costs**: On-chain transaction costs for locking and fulfilling the order
  - `lockin_gas_estimate`: Gas for `lockRequest()` call
  - `fulfill_gas_estimate`: Gas for `fulfill()` call
  - `groth16_verify_gas_estimate`: Gas for proof verification

### 3. Probability of Success (P(success))

In a complete implementation, this would account for:

```
P(success) = P(win_lock) × P(complete_on_time) × P(no_external_failure)
```

**P(win_lock)** - Probability of successfully locking the order:
- Depends on number of competing provers
- Can be estimated from recent lock success rates
- High-value orders attract more competition thus lower P(win_lock)

**P(complete_on_time)** - Probability of finishing proof before deadline. An implementtion can look like:
```
estimated_proving_time = total_cycles / peak_prove_khz
time_buffer = time_until_expiry - estimated_proving_time
```
- The probability of successful completion can be estimated based on the time
  buffer. The larger the buffer between the estimated proving time and the
  expiry, the greater the likelihood of success.

**P(no_external_failure)** - Order not cancelled or fulfilled by others.

## Version 1 Implementation (Current)

**Simplification:** Hardcode `P(success) = 1.0`

This makes the strategy effectively "**Highest Profit**" - sorting orders by
`(revenue - costs)` in descending order.

Orders are sorted by this value in **descending order** (highest profit first).

**Important:** Uses `saturating_sub()` so unprofitable orders (where costs >
revenue) get profit of 0 and are sorted last.

## Configuration

```toml
[market]
order_pricing_priority = "highest_expected_value"
order_commitment_priority = "highest_expected_value"

# Prices for cost calculation
mcycle_price = "0.00001"  # Price per megacycle in native token (ETH)

# Gas estimates
lockin_gas_estimate = 200000
fulfill_gas_estimate = 750000
groth16_verify_gas_estimate = 250000
```

**Note:**
- Gas price is currently hardcoded to 20 gwei in the implementation
- `mcycle_price` is parsed from config and converted from ETH to wei
- Future versions may fetch real-time gas prices from the network

## Use Cases

### High Profitability Optimization
**Scenario:** Prover wants to maximize revenue per unit of work **Strategy:**
`HighestExpectedValue` with P(success) = 1.0 **Result:** Prioritizes highest
profitable orders first

### Balanced Profit + Risk
**Scenario:** Prover wants to account for market competition **Strategy:**
`HighestExpectedValue` with dynamic P(win_lock) based on recent contention
**Result:** Avoids highly contested orders with low probability of success

### Time-Constrained Proving
**Scenario:** Limited proving capacity, need to maximize earnings **Strategy:**
`HighestExpectedValue` with P(complete_on_time) based on deadlines **Result:**
Avoids orders that might not finish in time

## Examples

### Example 1: High Payment, Low Cycles (High Profit)
```
Order A:
  maxPrice = 1 ETH = 1,000,000,000,000,000,000 wei
  total_cycles = 10,000,000 (10 mcycles)
  mcycle_price = 0.00001 ETH/mcycle

  proving_cost = 10 × 0.00001 ETH = 0.0001 ETH = 100,000,000,000,000 wei
  gas_cost = 1,200,000 gas × 20 gwei = 24,000,000,000,000,000 wei (0.024 ETH)
  total_cost = 0.0001 + 0.024 = 0.0241 ETH

  profit = 1 - 0.0241 = 0.9759 ETH ✓ Very high profit
```

### Example 2: Medium Payment, Medium Cycles (Medium Profit)
```
Order B:
  maxPrice = 0.1 ETH = 100,000,000,000,000,000 wei
  total_cycles = 100,000,000 (100 mcycles)

  proving_cost = 100 × 0.00001 ETH = 0.001 ETH
  gas_cost = 0.024 ETH
  total_cost = 0.025 ETH

  profit = 0.1 - 0.025 = 0.075 ETH ✓ Medium profit
```

### Example 3: Low Payment, High Cycles (Unprofitable)
```
Order C:
  maxPrice = 0.01 ETH = 10,000,000,000,000,000 wei
  total_cycles = 1,000,000,000 (1000 mcycles)

  proving_cost = 1000 × 0.00001 ETH = 0.01 ETH
  gas_cost = 0.024 ETH
  total_cost = 0.034 ETH

  profit = 0.01 - 0.034 = -0.024 ETH (saturates to 0) ✗ Unprofitable
```

**Prioritization:** Order A > Order B > Order C

Order C will be sorted last because its profit saturates to 0.

## Handling Edge Cases

### Orders with No Cycles

If `total_cycles` is `None`:
- Proving cost = 0
- Only gas costs are considered
- Profit = maxPrice - gas_costs

### Unprofitable Orders

Orders where `total_cost > revenue`:
- Use `saturating_sub()` which returns 0 instead of underflowing
- These orders get profit = 0
- Sorted to the end of the list (lowest priority)
- **Note:** They are not automatically skipped, just deprioritized

### Priority Addresses

The strategy respects priority addresses configuration:
1. **Priority orders** are grouped first, sorted by expected value within the
   group
2. **Regular orders** are grouped second, sorted by expected value within the
   group

This ensures important clients are always served first, regardless of
profitability.

## Future Enhancements

### Phase 2: Dynamic Probability

Implement `P(success)` calculation based on:
- Recent lock success rates (from database)
- Order characteristics (value-per-cycle percentile AKA maximize ROI per compute/sec)
- Time remaining until deadline
- Current network congestion

```rust
fn calculate_success_probability(order: &OrderRequest) -> f64 {
    let p_win_lock = estimate_lock_probability(order);
    let p_complete = estimate_completion_probability(order);
    let p_no_failure = 0.95;

    p_win_lock * p_complete * p_no_failure
}
```

### Phase 3: Real-Time Gas Pricing

Fetch current gas price from the network instead of using static 20 gwei:

```rust
let gas_price = provider.get_gas_price().await?;
let gas_costs = total_gas * gas_price;
```

### Phase 4: Dutch Auction Price

Use current auction price instead of maxPrice for more accurate revenue:

```rust
let current_price = calculate_dutch_auction_price(
    order.request.offer.minPrice,
    order.request.offer.maxPrice,
    order.request.offer.rampUpStart,
    current_timestamp,
);
```
## Testing Strategy

The implementation includes comprehensive tests:

### Unit Tests
- Verify profit calculation with known values
- Verify success probability on completing the order
- Verify orders without cycle data

### Integration Tests
- Verify sorting correctness (highest profit first)
- Priority addresses take precedence
- Handle negative profit (saturate to 0)
