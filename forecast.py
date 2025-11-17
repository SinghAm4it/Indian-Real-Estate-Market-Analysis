import pandas as pd
import numpy as np

# ---------------------------------------------------------
input_file = "C:/Users/cw/Downloads/Real Estate/clean_real_estate_with_cagr.csv"
output_file = "C:/Users/cw/Downloads/Real Estate/clean_real_estate_forecast.csv"
# ---------------------------------------------------------

# Load data
df = pd.read_csv(input_file)

# Columns
price_col = "Price_per_SQFT"
city_cagr_col = "City_Level_Annual_CAGR"
loc_cagr_col = "Locality_Level_Annual_CAGR"


# Select CAGR: use locality CAGR if present, else city CAGR
df["chosen_cagr"] = np.where(
    df[loc_cagr_col].notna(), 
    df[loc_cagr_col], 
    df[city_cagr_col]
)

# Identify source
df["cagr_source"] = np.where(
    df[loc_cagr_col].notna(), "locality",
    np.where(df[city_cagr_col].notna(), "city", "none")
)

# Forecast for 1, 2, 3 years — rounded to 2 decimals
df["Price_per_SQFT_plus_1yr"] = (df[price_col] * (1 + df["chosen_cagr"])**1).round(2)
df["Price_per_SQFT_plus_2yr"] = (df[price_col] * (1 + df["chosen_cagr"])**2).round(2)
df["Price_per_SQFT_plus_3yr"] = (df[price_col] * (1 + df["chosen_cagr"])**3).round(2)

# Save output
df.to_csv(output_file, index=False)
