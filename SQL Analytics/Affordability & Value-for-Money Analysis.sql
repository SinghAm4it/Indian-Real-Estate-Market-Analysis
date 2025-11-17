
/*
================================================================================
=  Affordability & Value-for-Money Analysis
=  Queries that measure affordability, BHK efficiency and value buckets
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) City-wise Affordability Index (avg sqft per crore)
   Purpose: compute mean sqft obtainable per 1 Cr in each city
--------------------------------------------------------------------------- */
WITH sqft_per_cr AS (
  SELECT
    City,
    (Total_Area / NULLIF(Price_in_Cr * 100, 0)) AS sqft_per_cr
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Total_Area IS NOT NULL
    AND Price_in_Cr IS NOT NULL
    AND Price_in_Cr > 0
),
ranked AS (
  SELECT
    City,
    sqft_per_cr,
    ROW_NUMBER() OVER (PARTITION BY City ORDER BY sqft_per_cr) AS rn,
    COUNT(*) OVER (PARTITION BY City) AS n
  FROM sqft_per_cr
)
SELECT
  City,
  ROUND(AVG(sqft_per_cr), 2) AS avg_sqft_per_crore,
  -- median: if n odd -> middle row; if n even -> avg of two middle rows
  ROUND(
    (CASE
      WHEN MOD(n, 2) = 1
        THEN MAX(IF(rn = (n + 1) / 2, sqft_per_cr, NULL))
      ELSE (MAX(IF(rn = n / 2, sqft_per_cr, NULL)) + MAX(IF(rn = n / 2 + 1, sqft_per_cr, NULL))) / 2
    END)
    , 2) AS median_sqft_per_crore,
  MAX(n) AS listings_count
FROM ranked
GROUP BY City, n
ORDER BY avg_sqft_per_crore DESC;

/* ---------------------------------------------------------------------------
   2) "BHK Efficiency Ratio" Across Cities
   Purpose: which BHKs give the most area per crore relative to ppsf
--------------------------------------------------------------------------- */
WITH bhk_stats AS (
  SELECT
    City,
    BHK_Type,
    COUNT(*) AS listings,
    AVG(Total_Area / NULLIF(Price_in_Cr*100,0)) AS avg_sqft_per_crore,
    AVG(Price_per_SQFT) AS avg_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND BHK_Type IS NOT NULL AND Price_in_Cr IS NOT NULL AND Total_Area IS NOT NULL
  GROUP BY City, BHK_Type
)
SELECT
  City,
  BHK_Type,
  listings,
  ROUND(avg_sqft_per_crore,2) AS avg_sqft_per_crore,
  ROUND(avg_ppsf,2) AS avg_ppsf,
  ROUND(avg_sqft_per_crore / NULLIF(avg_ppsf,0),3) AS bhk_efficiency_ratio
FROM bhk_stats
ORDER BY City, bhk_efficiency_ratio DESC;

/* ---------------------------------------------------------------------------
   3) "Sweet-spot" BHK for Each City (max sqft per Cr)
   Purpose: pick the BHK with maximum avg_sqft_per_crore in each city
--------------------------------------------------------------------------- */
WITH bhk_eff AS (
  SELECT
    City,
    BHK_Type,
    AVG(Total_Area / NULLIF(Price_in_Cr*100,0)) AS avg_sqft_per_crore,
    COUNT(*) AS n
  FROM clean_real_estate
  WHERE City IS NOT NULL AND BHK_Type IS NOT NULL AND Price_in_Cr IS NOT NULL AND Total_Area IS NOT NULL
  GROUP BY City, BHK_Type
),
ranked AS (
  SELECT
    City,
    BHK_Type,
    avg_sqft_per_crore,
    n,
    ROW_NUMBER() OVER (PARTITION BY City ORDER BY avg_sqft_per_crore DESC) AS rn
  FROM bhk_eff
)
SELECT
  City,
  BHK_Type AS sweet_spot_bhk,
  ROUND(avg_sqft_per_crore,2) AS sqft_per_cr,
  n AS listings_count
FROM ranked
WHERE rn = 1
ORDER BY City;

/* ---------------------------------------------------------------------------
   4) Best Value Configuration per City (min ppsf)
   Purpose: find config (Property_Type | BHK_Type) with lowest avg ppsf per city
--------------------------------------------------------------------------- */
WITH config_stats AS (
  SELECT
    City,
    CONCAT(Property_Type,' | ', BHK_Type) AS config,
    COUNT(*) AS listings,
    AVG(Price_per_SQFT) AS avg_ppsf,
    AVG(Total_Area / NULLIF(Price_in_Cr*100,0)) AS avg_sqft_per_cr
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL AND BHK_Type IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, config
),
ranked AS (
  SELECT
    City,
    config,
    listings,
    avg_ppsf,
    avg_sqft_per_cr,
    ROW_NUMBER() OVER (PARTITION BY City ORDER BY avg_ppsf ASC) AS rn_ppsf
  FROM config_stats
)
SELECT
  City,
  config AS best_value_config,
  listings,
  ROUND(avg_ppsf,2) AS avg_ppsf,
  ROUND(avg_sqft_per_cr,2) AS avg_sqft_per_cr
FROM ranked
WHERE rn_ppsf = 1
ORDER BY City;

/* ---------------------------------------------------------------------------
   5) "Starter Home" Filter (<=1 Cr & ppsf <= city p40)
   Purpose: count and describe starter-home inventory per city
--------------------------------------------------------------------------- */
WITH city_ntiles AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
city_p40 AS (
  SELECT City, MAX(Price_per_SQFT) AS p40_ppsf
  FROM city_ntiles
  WHERE pctile <= 40
  GROUP BY City
)
SELECT
  c.City,
  COUNT(*) AS starter_listings,
  ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf_starter,
  ROUND(AVG(Total_Area),1) AS avg_area_starter,
  ROUND(AVG(Price_in_Cr),2) AS avg_price_cr_starter
FROM clean_real_estate c
JOIN city_p40 p40 USING (City)
WHERE Price_in_Cr <= 1.0
  AND c.Price_per_SQFT <= p40.p40_ppsf
GROUP BY c.City
ORDER BY starter_listings DESC;

/* ---------------------------------------------------------------------------
   6) Locality Affordability Ranking (sqft per Cr)
   Purpose: rank localities by sqft you get per 1 Cr (filter thin localities)
--------------------------------------------------------------------------- */
WITH locality_afford AS (
  SELECT
    City,
    Locality,
    AVG(Total_Area / NULLIF(Price_in_Cr*100,0)) AS avg_sqft_per_cr,
    COUNT(*) AS listings
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Total_Area IS NOT NULL AND Price_in_Cr IS NOT NULL
  GROUP BY City, Locality
)
SELECT
  City,
  Locality,
  ROUND(avg_sqft_per_cr,1) AS avg_sqft_per_cr,
  listings,
  ROW_NUMBER() OVER (PARTITION BY City ORDER BY avg_sqft_per_cr DESC) AS locality_afford_rank
FROM locality_afford
WHERE listings >= 5
ORDER BY City, locality_afford_rank;

/* ---------------------------------------------------------------------------
   7) "Budget Hotspots" Density (<= city p25 ppsf)
   Purpose: find localities with concentrated cheap listings
--------------------------------------------------------------------------- */
WITH city_ntiles AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
city_p25 AS (
  SELECT City, MAX(Price_per_SQFT) AS p25_ppsf
  FROM city_ntiles
  WHERE pctile <= 25
  GROUP BY City
),
cheap_listings AS (
  SELECT c.City, c.Locality
  FROM clean_real_estate c
  JOIN city_p25 p ON c.City = p.City
  WHERE c.Price_per_SQFT <= p.p25_ppsf
)
SELECT
  cl.City,
  cl.Locality,
  COUNT(*) AS cheap_listing_count,
  ROUND(COUNT(*) / NULLIF((SELECT COUNT(*) FROM clean_real_estate r WHERE r.City = cl.City AND r.Locality = cl.Locality),0) * 100,2) AS pct_of_locality_cheap
FROM cheap_listings cl
GROUP BY cl.City, cl.Locality
HAVING cheap_listing_count >= 5
ORDER BY cl.City, cheap_listing_count DESC;

/* ---------------------------------------------------------------------------
   8) Balance of Options Across Price Tiers (Evenness)
   Purpose: compute a simple evenness index across 5 price quintiles
--------------------------------------------------------------------------- */
WITH city_buckets AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(5) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS quintile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
city_bucket_counts AS (
  SELECT
    City,
    quintile,
    COUNT(*) AS cnt
  FROM city_buckets
  GROUP BY City, quintile
),
city_totals AS (
  SELECT City, SUM(cnt) AS total
  FROM city_bucket_counts
  GROUP BY City
)
SELECT
  cbc.City,
  -- evenness index = sum of squared shares across quintiles (smaller -> more even)
  ROUND(SUM( POWER( cnt / NULLIF(ct.total, 0), 2) ), 4) AS evenness_index,
  -- human-readable counts by quintile (Q1:xx, Q2:yy, ...)
  GROUP_CONCAT(CONCAT('Q', cbc.quintile, ':', cbc.cnt) ORDER BY cbc.quintile SEPARATOR ', ') AS counts_by_quintile
FROM city_bucket_counts cbc
JOIN city_totals ct USING (City)
GROUP BY cbc.City
ORDER BY evenness_index ASC;