# 🔍 Exploratory Data Analysis (EDA) Report

## 🎯 Objective
The goal of EDA was to:
- Understand **price behavior** across cities & localities
- Detect **data quality issues**
- Prepare data for **advanced SQL analytics & forecasting**

---

## 🧹 Data Cleaning & Standardization

### ✔ Null Handling
- Removed rows with missing:
  - City
  - Price per SQFT
  - Total Area
- Ensured meaningful statistical computations

### ✔ BHK Normalization
- Parsed numeric BHK values from text labels  
  (`"2 BHK" → 2`, `"2.5 BHK" → 2.5`)
- Enabled ladder analysis & elasticity calculations

### ✔ Price Consistency Checks
- Recomputed `Price_per_SQFT` using:
(Price_in_Cr × 10,000,000) / Total_Area

yaml
Copy code
- Flagged large mismatches for anomaly analysis

---

## 📊 Univariate Analysis

### 🏙️ City Level
- Distribution of listings per city
- Mean vs median price gaps
- Price dispersion via:
- Standard deviation
- IQR & MAD (robust metrics)

### 🏘️ Locality Level
- Identified:
- Thin localities (low volume)
- Volatile localities
- Price-skewed regions

---

## 🔗 Multivariate Exploration

### 📐 Area vs Price
- Log-log relationships tested
- Elasticity varies across cities
- Confirmed **non-linear pricing behavior**

### 🛏️ BHK & Property Type
- Certain BHKs consistently offer:
- Better area per crore
- Lower price inefficiency
- Builder floors & villas show higher volatility

---

## ⚠️ Outlier Detection (EDA Stage)

Used multiple methods:
- Z-score (city-level)
- IQR (locality-level)
- Cross-metric mismatch (price vs area)

This justified the **deep anomaly framework** later built in SQL.

---

## 🧠 EDA Outcome
EDA helped:
- Validate dataset reliability
- Choose correct segmentation logic
- Design advanced SQL metrics confidently

It laid the foundation for **robust business-grade analytics**.
