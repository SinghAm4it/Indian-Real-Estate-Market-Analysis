
/*
================================================================================
=  Feature Efficiency & Amenity Value
=  How features (BHK, Baths, Balcony, Property Type) translate into price/value
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) BHK Price Efficiency
   Purpose: how much area per crore and ppsf per BHK; efficiency ratio = area_per_cr / avg_ppsf
--------------------------------------------------------------------------- */
WITH bhk_stats AS (
  SELECT
    City,
    BHK_Type,
    COUNT(*) AS listings,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf,
    ROUND(AVG(Total_Area / NULLIF(Price_in_Cr*100,0)),2) AS avg_sqft_per_cr
  FROM clean_real_estate
  WHERE City IS NOT NULL AND BHK_Type IS NOT NULL
    AND Price_per_SQFT IS NOT NULL AND Total_Area IS NOT NULL AND Price_in_Cr IS NOT NULL
  GROUP BY City, BHK_Type
)
SELECT
  City,
  BHK_Type,
  listings,
  avg_ppsf,
  avg_sqft_per_cr,
  ROUND(avg_sqft_per_cr / NULLIF(avg_ppsf,0),4) AS bhk_efficiency_ratio
FROM bhk_stats
ORDER BY City, bhk_efficiency_ratio DESC;

/* ---------------------------------------------------------------------------
   2) Amenity Impact on Price (Baths & Balcony) - simple multivariate proxy
   Purpose: estimate ppsf uplift per bath and balcony using cov/var (city-level)
--------------------------------------------------------------------------- */
WITH amenity_base AS (
  SELECT
    City,
    Baths,
    CASE
      WHEN Balcony IS NULL THEN 0
      WHEN LOWER(TRIM(Balcony)) IN ('no') THEN 0
      ELSE 1
    END AS has_balcony,
    Price_per_SQFT
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Price_per_SQFT IS NOT NULL
    AND Baths IS NOT NULL
),
city_means AS (
  -- compute the per-city means once
  SELECT
    City,
    AVG(Price_per_SQFT) AS city_mean_ppsf,
    AVG(Baths) AS mean_baths,
    AVG(CASE WHEN has_balcony = 1 THEN Price_per_SQFT END) AS mean_ppsf_balcony,
    AVG(CASE WHEN has_balcony = 0 THEN Price_per_SQFT END) AS mean_ppsf_no_balcony,
    COUNT(*) AS n
  FROM amenity_base
  GROUP BY City
),
city_sums AS (
  -- compute sums needed for covariance and variance by joining rows to city means
  SELECT
    a.City,
    SUM( (a.Baths - cm.mean_baths) * (a.Price_per_SQFT - cm.city_mean_ppsf) ) AS sum_cov_baths_ppsf,
    SUM( POWER(a.Baths - cm.mean_baths, 2) ) AS sum_var_baths,
    cm.city_mean_ppsf,
    cm.mean_ppsf_balcony,
    cm.mean_ppsf_no_balcony,
    cm.n
  FROM amenity_base a
  JOIN city_means cm USING (City)
  GROUP BY a.City
)
SELECT
  City,
  -- slope: ppsf change per unit bath (OLS slope = cov / var_x)
  ROUND( CASE WHEN sum_var_baths > 0 THEN sum_cov_baths_ppsf / NULLIF(sum_var_baths,0) ELSE NULL END, 4) AS slope_ppsf_per_bath,
  -- simple average ppsf uplift for listings with balcony vs without
  ROUND( (mean_ppsf_balcony - mean_ppsf_no_balcony), 2 ) AS avg_ppsf_balcony_uplift,
  ROUND(city_mean_ppsf, 2) AS city_mean_ppsf,
  n AS listings_count
FROM city_sums
ORDER BY City;

/* ---------------------------------------------------------------------------
   3) Area Efficiency Analysis (top listings that maximize sqft per Cr)
   Purpose: list top area-efficient listings per city (use Total_Area)
--------------------------------------------------------------------------- */
WITH base AS (
  SELECT
    City,
    Locality,
    Price_in_Cr,
    Total_Area,
    (Total_Area / NULLIF(Price_in_Cr*100,0)) AS sqft_per_cr
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Total_Area IS NOT NULL AND Price_in_Cr IS NOT NULL
),
top_listings AS (
  SELECT
    City,
    Locality,
    Price_in_Cr,
    Total_Area,
    ROUND(sqft_per_cr,2) AS sqft_per_cr,
    ROW_NUMBER() OVER (PARTITION BY City ORDER BY sqft_per_cr DESC) AS rn
  FROM base
)
SELECT
  City,
  Locality,
  Price_in_Cr,
  Total_Area,
  sqft_per_cr
FROM top_listings
WHERE rn <= 10
ORDER BY City, sqft_per_cr DESC;

/* ---------------------------------------------------------------------------
   4) BHK Ladder: Per-step Premium (per City)
   Purpose: how much price jumps on average moving from N to N+1 BHK (Price_in_Cr)
--------------------------------------------------------------------------- */
WITH bhk_parsed AS (
  SELECT
    City,
    BHK_Type,
    NULLIF(CAST(REGEXP_REPLACE(BHK_Type, '[^0-9]', '') AS UNSIGNED), 0) AS bhk_num,
    Price_in_Cr
  FROM clean_real_estate
  WHERE City IS NOT NULL AND BHK_Type IS NOT NULL AND Price_in_Cr IS NOT NULL
),
bhk_stats AS (
  SELECT
    City,
    bhk_num,
    COUNT(*) AS listings,
    AVG(Price_in_Cr) AS avg_price_cr
  FROM bhk_parsed
  WHERE bhk_num IS NOT NULL
  GROUP BY City, bhk_num
),
lagged AS (
  SELECT
    City,
    bhk_num,
    listings,
    avg_price_cr,
    LAG(avg_price_cr) OVER (PARTITION BY City ORDER BY bhk_num) AS prev_avg_price_cr
  FROM bhk_stats
)
SELECT
  City,
  bhk_num,
  listings,
  ROUND(avg_price_cr,2) AS avg_price_cr,
  ROUND(prev_avg_price_cr,2) AS prev_avg_price_cr,
  ROUND( (avg_price_cr - prev_avg_price_cr),2) AS step_premium_cr,
  ROUND( ( (avg_price_cr - prev_avg_price_cr) / NULLIF(prev_avg_price_cr,0) ) * 100,2) AS step_premium_pct
FROM lagged
WHERE prev_avg_price_cr IS NOT NULL
ORDER BY City, bhk_num;

/* ---------------------------------------------------------------------------
   5) Over/Under-sized by BHK (area z-score within BHK)
   Purpose: flag unusually large or small units relative to their BHK group
--------------------------------------------------------------------------- */
WITH bhk_clean AS (
  SELECT
    City,
    BHK_Type,
    Total_Area
  FROM clean_real_estate
  WHERE City IS NOT NULL AND BHK_Type IS NOT NULL AND Total_Area IS NOT NULL
),
bhk_stats AS (
  SELECT
    City,
    BHK_Type,
    COUNT(*) AS n,
    AVG(Total_Area) AS mean_area,
    STDDEV_POP(Total_Area) AS sd_area
  FROM bhk_clean
  GROUP BY City, BHK_Type
),
joined AS (
  SELECT
    c.*,
    s.mean_area,
    s.sd_area,
    (c.Total_Area - s.mean_area) / NULLIF(s.sd_area,0) AS area_zscore
  FROM bhk_clean c
  JOIN bhk_stats s USING (City, BHK_Type)
)
SELECT
  City,
  BHK_Type,
  Total_Area,
  ROUND(area_zscore,3) AS area_zscore,
  CASE
    WHEN area_zscore >= 2 THEN 'oversized'
    WHEN area_zscore <= -2 THEN 'undersized'
    ELSE 'typical'
  END AS size_flag
FROM joined
ORDER BY City, BHK_Type, area_zscore DESC
LIMIT 1000;

/* ---------------------------------------------------------------------------
   6) Amenity-adjusted PPSF (simple 2-variable regression proxy)
   Purpose: city-level coefficients for Price_per_SQFT ~ Baths + Has_Balcony
--------------------------------------------------------------------------- */
WITH xformed AS (
  SELECT
    City,
    Price_per_SQFT AS y,
    Baths AS x1,
    CASE WHEN Balcony IS NULL THEN 0 WHEN LOWER(TRIM(Balcony)) IN ('0','no','n','none') THEN 0 ELSE 1 END AS x2
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL AND Baths IS NOT NULL
),
sums AS (
  SELECT
    City,
    COUNT(*) AS n,
    SUM(y) AS sum_y,
    SUM(x1) AS sum_x1,
    SUM(x2) AS sum_x2,
    SUM(x1*x1) AS sum_x1x1,
    SUM(x2*x2) AS sum_x2x2,
    SUM(x1*x2) AS sum_x1x2,
    SUM(x1*y) AS sum_x1y,
    SUM(x2*y) AS sum_x2y
  FROM xformed
  GROUP BY City
),
coeffs AS (
  SELECT
    City,
    n,
    sum_y / n AS mean_y,
    sum_x1 / n AS mean_x1,
    sum_x2 / n AS mean_x2,
    (sum_x1x1 - (sum_x1*sum_x1)/n) AS S11,
    (sum_x1x2 - (sum_x1*sum_x2)/n) AS S12,
    (sum_x2x2 - (sum_x2*sum_x2)/n) AS S22,
    (sum_x1y - (sum_x1*sum_y)/n) AS S1y,
    (sum_x2y - (sum_x2*sum_y)/n) AS S2y
  FROM sums
),
solve AS (
  SELECT
    City,
    n,
    mean_y,
    mean_x1,
    mean_x2,
    S11, S12, S22, S1y, S2y,
    (S11 * S22 - S12 * S12) AS det,
    CASE WHEN (S11 * S22 - S12 * S12) != 0 THEN ( (S1y * S22 - S2y * S12) / (S11 * S22 - S12 * S12) ) ELSE NULL END AS beta1,
    CASE WHEN (S11 * S22 - S12 * S12) != 0 THEN ( (S2y * S11 - S1y * S12) / (S11 * S22 - S12 * S12) ) ELSE NULL END AS beta2
  FROM coeffs
)
SELECT
  City,
  n,
  ROUND(mean_y,3) AS mean_ppsf,
  ROUND(beta1,4) AS coeff_ppsf_per_bath,
  ROUND(beta2,4) AS coeff_ppsf_balcony_binary,
  ROUND( (mean_y - COALESCE(beta1,0)*mean_x1 - COALESCE(beta2,0)*mean_x2),3) AS intercept_alpha
FROM solve
ORDER BY City;

/* ---------------------------------------------------------------------------
   7) Type Premium vs City Average
   Purpose: how much each property type deviates from city avg ppsf
--------------------------------------------------------------------------- */
WITH city_avg AS (
  SELECT City, AVG(Price_per_SQFT) AS city_avg_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City
),
type_stats AS (
  SELECT
    c.City,
    c.Property_Type,
    COUNT(*) AS listings,
    AVG(c.Price_per_SQFT) AS type_avg_ppsf
  FROM clean_real_estate c
  WHERE c.City IS NOT NULL AND c.Property_Type IS NOT NULL AND c.Price_per_SQFT IS NOT NULL
  GROUP BY c.City, c.Property_Type
)
SELECT
  t.City,
  t.Property_Type,
  t.listings,
  ROUND(t.type_avg_ppsf,2) AS type_avg_ppsf,
  ROUND(c.city_avg_ppsf,2) AS city_avg_ppsf,
  ROUND( (t.type_avg_ppsf - c.city_avg_ppsf),2) AS delta_ppsf,
  CONCAT(ROUND( (t.type_avg_ppsf / NULLIF(c.city_avg_ppsf,0) - 1) * 100,2), '%') AS pct_vs_city_avg
FROM type_stats t
JOIN city_avg c USING (City)
ORDER BY City, delta_ppsf DESC;

/* ---------------------------------------------------------------------------
   8) Price-per-Bath Affordability
   Purpose: price and area metrics normalized per bathroom
--------------------------------------------------------------------------- */
WITH bath_clean AS (
  SELECT
    City,
    Locality,
    Price_in_Cr,
    Total_Area,
    Baths
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_in_Cr IS NOT NULL AND Total_Area IS NOT NULL AND Baths IS NOT NULL AND Baths > 0
),
bath_stats AS (
  SELECT
    City,
    COUNT(*) AS n,
    ROUND(AVG(Price_in_Cr / NULLIF(Baths,0)),3) AS avg_price_cr_per_bath,
    ROUND(AVG(Total_Area / NULLIF(Baths,0)),1) AS avg_sqft_per_bath,
    ROUND(AVG( (Total_Area / NULLIF(Price_in_Cr*100,0)) / NULLIF(Baths,0) ),2) AS avg_sqft_per_cr_per_bath
  FROM bath_clean
  GROUP BY City
)
SELECT
  City,
  n,
  avg_price_cr_per_bath,
  avg_sqft_per_bath,
  avg_sqft_per_cr_per_bath
FROM bath_stats
ORDER BY avg_sqft_per_cr_per_bath DESC;
