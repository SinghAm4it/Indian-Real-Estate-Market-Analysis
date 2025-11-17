
/*
================================================================================
=  Advanced Market Dynamics & Interaction Effects
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) Feature Interaction Grid
   Purpose: average ppsf and metrics by City × Property_Type × BHK_Type
--------------------------------------------------------------------------- */
WITH combos AS (
  SELECT
    City,
    Property_Type,
    BHK_Type,
    COUNT(*) AS listings,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf,
    ROUND(AVG(Price_in_Cr),3) AS avg_price_cr,
    ROUND(AVG(Total_Area),1) AS avg_area
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL AND BHK_Type IS NOT NULL
  GROUP BY City, Property_Type, BHK_Type
)
SELECT
  City,
  Property_Type,
  BHK_Type,
  listings,
  avg_ppsf,
  avg_price_cr,
  avg_area,
  ROUND( avg_ppsf / NULLIF( (SELECT AVG(Price_per_SQFT) FROM clean_real_estate r WHERE r.City = c.City), 0), 3) AS rel_to_city_ppsf
FROM combos c
ORDER BY City, Property_Type, avg_ppsf DESC;

/* ---------------------------------------------------------------------------
   2) Type-specific Volatility vs City Baseline (compact)
   Purpose: compare sd of ppsf per Property_Type against city sd
--------------------------------------------------------------------------- */
WITH city_stats AS (
  SELECT
    City,
    STDDEV_POP(Price_per_SQFT) AS city_sd_ppsf,
    AVG(Price_per_SQFT) AS city_mean_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City
),
type_stats AS (
  SELECT
    City,
    Property_Type,
    COUNT(*) AS listings,
    AVG(Price_per_SQFT) AS type_mean_ppsf,
    STDDEV_POP(Price_per_SQFT) AS type_sd_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, Property_Type
)
SELECT
  t.City,
  t.Property_Type,
  t.listings,
  ROUND(t.type_mean_ppsf,2) AS type_mean_ppsf,
  ROUND(t.type_sd_ppsf,2) AS type_sd_ppsf,
  ROUND(c.city_sd_ppsf,2) AS city_sd_ppsf,
  ROUND( t.type_sd_ppsf / NULLIF(c.city_sd_ppsf,0),3) AS volatility_ratio
FROM type_stats t
JOIN city_stats c USING (City)
ORDER BY City, volatility_ratio DESC;

/* ---------------------------------------------------------------------------
   3) Combined z-score anomaly (ppsf & Total_Area)
   Purpose: Euclidean anomaly score in z-space and flags for high anomalies
--------------------------------------------------------------------------- */
WITH city_stats AS (
  SELECT
    City,
    AVG(Price_per_SQFT) AS mean_ppsf,
    STDDEV_POP(Price_per_SQFT) AS sd_ppsf,
    AVG(Total_Area) AS mean_area,
    STDDEV_POP(Total_Area) AS sd_area
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL AND Total_Area IS NOT NULL
  GROUP BY City
),
scored AS (
  SELECT
    r.City,
    r.Locality,
    r.Price_per_SQFT,
    r.Total_Area,
    (r.Price_per_SQFT - s.mean_ppsf) / NULLIF(s.sd_ppsf,0) AS z_ppsf,
    (r.Total_Area - s.mean_area) / NULLIF(s.sd_area,0) AS z_area
  FROM clean_real_estate r
  JOIN city_stats s USING (City)
),
combined AS (
  SELECT
    City,
    Locality,
    Price_per_SQFT,
    Total_Area,
    ROUND(z_ppsf,3) AS z_ppsf,
    ROUND(z_area,3) AS z_area,
    ROUND( SQRT( POWER(z_ppsf,2) + POWER(z_area,2) ),3) AS anomaly_score,
    ROUND( GREATEST(ABS(z_ppsf), ABS(z_area)),3) AS max_univariate_z
  FROM scored
)
SELECT
  City,
  Locality,
  Price_per_SQFT,
  Total_Area,
  z_ppsf,
  z_area,
  anomaly_score,
  max_univariate_z,
  CASE
    WHEN anomaly_score > 4 OR max_univariate_z > 3 THEN 'high_anomaly'
    WHEN anomaly_score > 2.5 THEN 'medium_anomaly'
    ELSE 'normal'
  END AS anomaly_flag
FROM combined
ORDER BY anomaly_score DESC
LIMIT 500;
