
/*
================================================================================
=  Price Structure & Segmentation
=  Queries grouped for city / locality price segmentation and comparisons
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) City & Locality Price Segmentation
   Purpose: summary stats (count, avg, median approx, sd, min, max) per City+Locality
   Tip: treat 'thin' localities cautiously (small sample size).
--------------------------------------------------------------------------- */
WITH numbered AS (
  SELECT
    City,
    Locality,
    Price_per_SQFT,
    ROW_NUMBER() OVER (PARTITION BY City, Locality ORDER BY Price_per_SQFT) AS rn,
    COUNT(*) OVER (PARTITION BY City, Locality) AS cnt,
    AVG(Price_per_SQFT) OVER (PARTITION BY City, Locality) AS avg_ppsf,
    STDDEV_POP(Price_per_SQFT) OVER (PARTITION BY City, Locality) AS sd_ppsf,
    MIN(Price_per_SQFT) OVER (PARTITION BY City, Locality) AS min_ppsf,
    MAX(Price_per_SQFT) OVER (PARTITION BY City, Locality) AS max_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
medians AS (
  SELECT
    City,
    Locality,
    CASE
       WHEN COUNT(*) % 2 = 1 THEN 
          MAX(CASE WHEN rn = (cnt+1)/2 THEN Price_per_SQFT END)
    ELSE 
        (
          MAX(CASE WHEN rn = (cnt/2) THEN Price_per_SQFT END)
          +
          MAX(CASE WHEN rn = (cnt/2)+1 THEN Price_per_SQFT END)
        ) / 2
    END AS median_ppsf,
    MAX(avg_ppsf) AS avg_ppsf,
    MAX(sd_ppsf) AS sd_ppsf,
    MAX(min_ppsf) AS min_ppsf,
    MAX(max_ppsf) AS max_ppsf,
    MAX(cnt) AS listings_count
  FROM numbered
  GROUP BY City, Locality
)
SELECT
  City,
  Locality,
  listings_count,
  ROUND(avg_ppsf,2) AS avg_ppsf,
  ROUND(median_ppsf,2) AS median_ppsf,
  ROUND(sd_ppsf,2) AS sd_ppsf,
  ROUND(min_ppsf,2) AS min_ppsf,
  ROUND(max_ppsf,2) AS max_ppsf,
  CASE
    WHEN listings_count >= 30 THEN 'mature'
    WHEN listings_count >= 10 THEN 'growing'
    ELSE 'thin'
  END AS coverage_band
FROM medians
ORDER BY City, avg_ppsf DESC;

/* ---------------------------------------------------------------------------
   2) Property Type Comparison
   Purpose: compare avg ppsf, dispersion and share relative to city average per Property_Type
--------------------------------------------------------------------------- */
WITH stats AS (
  SELECT
    City,
    Property_Type,
    COUNT(*) AS listings,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf,
    ROUND(MIN(Price_per_SQFT),2) AS min_ppsf,
    ROUND(MAX(Price_per_SQFT),2) AS max_ppsf,
    ROUND(STDDEV_POP(Price_per_SQFT),2) AS sd_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, Property_Type
)
SELECT
  s.City,
  s.Property_Type,
  s.listings,
  s.avg_ppsf,
  s.min_ppsf,
  s.max_ppsf,
  s.sd_ppsf,
  CONCAT(ROUND((s.avg_ppsf / NULLIF(c.city_avg_ppsf,0)) * 100,1),'%') AS pct_of_city_avg
FROM stats s
JOIN (
  SELECT City, AVG(Price_per_SQFT) AS city_avg_ppsf FROM clean_real_estate
  WHERE Price_per_SQFT IS NOT NULL
  GROUP BY City
) c ON c.City = s.City
ORDER BY s.City, s.avg_ppsf DESC;

/* ---------------------------------------------------------------------------
   3) Locality Price Gradient (within City)
   Purpose: show how locality avg ppsf compares to mean of localities in the city
--------------------------------------------------------------------------- */
WITH locality_stats AS (
  SELECT
    City,
    Locality,
    COUNT(*) AS listings,
    ROUND(AVG(Price_per_SQFT),2) AS locality_avg_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, Locality
),
city_stats AS (
  SELECT
    City,
    ROUND(AVG(locality_avg_ppsf),2) AS city_mean_locality_ppsf,
    ROUND(STDDEV_POP(locality_avg_ppsf),2) AS city_sd_locality_ppsf
  FROM locality_stats
  GROUP BY City
)
SELECT
  l.City,
  l.Locality,
  l.listings,
  l.locality_avg_ppsf,
  cs.city_mean_locality_ppsf,
  ROUND( (l.locality_avg_ppsf - cs.city_mean_locality_ppsf) / NULLIF(cs.city_mean_locality_ppsf,0) * 100,2) AS pct_diff_from_city_avg,
  CASE
    WHEN l.locality_avg_ppsf >= cs.city_mean_locality_ppsf + 2*cs.city_sd_locality_ppsf THEN 'high_gap'
    WHEN l.locality_avg_ppsf <= cs.city_mean_locality_ppsf - 2*cs.city_sd_locality_ppsf THEN 'low_gap'
    ELSE 'within_range'
  END AS gradient_band
FROM locality_stats l
JOIN city_stats cs USING (City)
ORDER BY City, pct_diff_from_city_avg DESC;

/* ---------------------------------------------------------------------------
   4) Cross-tab: BHK vs Property Type (compact readable cross-tab)
   Purpose: show which property types are most common per BHK and avg ppsf
--------------------------------------------------------------------------- */
WITH counts AS (
  -- one row per BHK_Type x Property_Type with the true count
  SELECT
    BHK_Type,
    Property_Type,
    COUNT(*) AS cnt,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf_for_group
  FROM clean_real_estate
  WHERE BHK_Type IS NOT NULL
    AND Property_Type IS NOT NULL
  GROUP BY BHK_Type, Property_Type
),
avg_bhk AS (
  SELECT 
    BHK_Type,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf_per_bhk
  FROM clean_real_estate
  WHERE BHK_Type IS NOT NULL
  GROUP BY BHK_Type
)
SELECT
  c.BHK_Type,
  c.Property_Type,
  c.cnt,
  SUM(c.cnt) OVER (PARTITION BY c.BHK_Type) AS total_listings_per_bhk,   
  a.avg_ppsf_per_bhk
FROM counts c
JOIN avg_bhk a USING (BHK_Type)
ORDER BY c.BHK_Type, total_listings_per_bhk DESC, c.cnt DESC;

/* ---------------------------------------------------------------------------
   5) Locality Volume vs. Average Price Relationship
   Purpose: Pearson correlation (listings count vs avg ppsf) per city
--------------------------------------------------------------------------- */
WITH locality AS (
  SELECT
    City,
    Locality,
    COUNT(*) AS listings,
    ROUND(AVG(Price_per_SQFT),2) AS avg_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, Locality
),
city_means AS (
  -- precompute the per-city means so we can use them as constants below
  SELECT
    City,
    AVG(listings) AS mean_listings,
    AVG(avg_ppsf) AS mean_avg_ppsf
  FROM locality
  GROUP BY City
)
SELECT
  l.City,
  -- covariance / sqrt(var_x * var_y)
  ROUND(
    SUM( (l.listings - cm.mean_listings) * (l.avg_ppsf - cm.mean_avg_ppsf) )
    / NULLIF( SQRT(
        SUM( POWER(l.listings - cm.mean_listings, 2) ) * SUM( POWER(l.avg_ppsf - cm.mean_avg_ppsf, 2) )
      ), 0)
  , 3) AS pearson_corr_listings_vs_ppsf,
  COUNT(*) AS locality_count
FROM locality l
JOIN city_means cm USING (City)
GROUP BY l.City
ORDER BY l.City;

/* ---------------------------------------------------------------------------
   6) Type-adjusted Locality Ranking
   Purpose: compute locality expected ppsf given city-type averages and compare to actual
   Idea: tells if locality premium exists beyond type composition
--------------------------------------------------------------------------- */
WITH city_property_avg AS (
  SELECT
    City,
    Property_Type,
    AVG(Price_per_SQFT) AS city_type_avg_ppsf,
    COUNT(*) AS cnt_type
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City, Property_Type
),
locality_mix AS (
  -- counts of each property type inside each locality
  SELECT
    City,
    Locality,
    Property_Type,
    COUNT(*) AS cnt_local_type
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Property_Type IS NOT NULL
  GROUP BY City, Locality, Property_Type
),
locality_counts AS (
  -- total listings per locality (to turn counts into shares)
  SELECT
    City,
    Locality,
    SUM(cnt_local_type) AS total_local_listings
  FROM locality_mix
  GROUP BY City, Locality
),
locality_expected AS (
  -- expected ppsf per locality given its type mix and city-type averages
  SELECT
    lm.City,
    lm.Locality,
    SUM( (lm.cnt_local_type / NULLIF(lc.total_local_listings,0)) * cpa.city_type_avg_ppsf ) AS expected_ppsf
  FROM locality_mix lm
  JOIN locality_counts lc
    ON lm.City = lc.City AND lm.Locality = lc.Locality
  JOIN city_property_avg cpa
    ON lm.City = cpa.City AND lm.Property_Type = cpa.Property_Type
  GROUP BY lm.City, lm.Locality
),
locality_actual AS (
  -- actual observed locality stats
  SELECT City, Locality, COUNT(*) AS listings, AVG(Price_per_SQFT) AS actual_avg_ppsf
  FROM clean_real_estate
  GROUP BY City, Locality
)
SELECT
  a.City,
  a.Locality,
  a.listings,
  ROUND(a.actual_avg_ppsf,2) AS actual_avg_ppsf,
  ROUND(le.expected_ppsf,2) AS expected_ppsf_based_on_city_type_mix,
  ROUND(a.actual_avg_ppsf - le.expected_ppsf,2) AS type_adjusted_delta,
  CASE
    WHEN a.actual_avg_ppsf - le.expected_ppsf > 0 THEN 'premium_after_adjust'
    WHEN a.actual_avg_ppsf - le.expected_ppsf < 0 THEN 'discount_after_adjust'
    ELSE 'in_line'
  END AS adjusted_rank_flag
FROM locality_actual a
JOIN locality_expected le
  ON a.City = le.City AND a.Locality = le.Locality
ORDER BY a.City, type_adjusted_delta DESC;

/* ---------------------------------------------------------------------------
   7) BHK Spectrum Coverage (how wide each city’s BHK menu is)
   Purpose: measure textual and numeric variety in BHK offerings
--------------------------------------------------------------------------- */
WITH normalized AS (
  -- use robust extraction as above
  SELECT City,
         CAST(NULLIF(REPLACE(REGEXP_SUBSTR(BHK_Type, '[0-9]+(\\.[0-9]+)?'), ',', '.'), '') AS DECIMAL(6,1)) AS bhk_num,
         BHK_Type
  FROM clean_real_estate
  WHERE BHK_Type IS NOT NULL
),
agg AS (
  SELECT City,
         COUNT(DISTINCT BHK_Type) AS distinct_bhk_labels,
         COUNT(DISTINCT bhk_num) AS distinct_numeric_bhk,
         MIN(bhk_num) AS min_bhk,
         MAX(bhk_num) AS max_bhk
  FROM normalized
  GROUP BY City
)
SELECT
  City,
  distinct_bhk_labels,
  distinct_numeric_bhk,
  -- if integer, show without decimals, else show as-is (string)
  IF(min_bhk = FLOOR(min_bhk), CAST(FLOOR(min_bhk) AS CHAR), CAST(min_bhk AS CHAR)) AS min_bhk,
  IF(max_bhk = FLOOR(max_bhk), CAST(FLOOR(max_bhk) AS CHAR), CAST(max_bhk AS CHAR)) AS max_bhk,
  CONCAT(
    IF(min_bhk = FLOOR(min_bhk), CAST(FLOOR(min_bhk) AS CHAR), CAST(min_bhk AS CHAR)),
    '-',
    IF(max_bhk = FLOOR(max_bhk), CAST(FLOOR(max_bhk) AS CHAR), CAST(max_bhk AS CHAR))
  ) AS numeric_range,
  CASE
    WHEN distinct_bhk_labels >= 6 THEN 'wide'
    WHEN distinct_bhk_labels >= 3 THEN 'moderate'
    ELSE 'narrow'
  END AS spectrum_band
FROM agg
ORDER BY City;
