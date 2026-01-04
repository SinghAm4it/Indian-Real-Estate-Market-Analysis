# 🔮 Price Forecasting Report

## 🎯 Objective
Estimate **future Price per SQFT (1–3 years)** using:
- Historical CAGR patterns
- City & locality growth signals

---

## 🧮 Forecast Methodology

### 📈 CAGR Selection Logic
For each listing:
- Use **Locality CAGR** if available
- Else fallback to **City CAGR**
- Else mark as `no forecast`

This ensures **maximum granularity without data loss**.

---

## 🧠 Forecast Formula
For year `n`:
Future_Price = Current_Price × (1 + CAGR)^n


Computed for:
- +1 year
- +2 years
- +3 years

---

## 🗂 Output Fields
- `Price_per_SQFT_plus_1yr`
- `Price_per_SQFT_plus_2yr`
- `Price_per_SQFT_plus_3yr`
- `chosen_cagr`
- `cagr_source` (city / locality)

---

## 📊 Use Cases

### 🏢 Developers
- Price launches dynamically
- Identify fast-appreciating micro-markets

### 💼 Investors
- Compare current vs future valuation
- Prioritize localities with compounding growth

### 🏦 Lending & Risk Teams
- Stress-test price assumptions
- Detect overheated markets

---

## ⚠️ Limitations
- CAGR assumes **smooth growth**
- Does not model:
  - Policy shocks
  - Interest rate changes
  - Supply surges

---

## 🏁 Final Note
This forecast is based on the **CAGR data available on the internet**.
