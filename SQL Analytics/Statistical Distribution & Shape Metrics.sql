
/*
================================================================================
=  Statistical Distribution & Shape Metrics
=  Skewness, kurtosis, Lorenz deciles, log-log non-linearity and Simpson check
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) Price Distribution Buckets per City (Lorenz deciles)
   Purpose: produce decile cumulative shares for Lorenz curve plotting
--------------------------------------------------------------------------- */
WITH city_ordered AS (
  SELECT
    City,
    Price_in_Cr,
    Price_in_Cr * 1.0 AS value_cr,
    NTILE(10) OVER (PARTITION BY City ORDER BY Price_in_Cr ASC) AS decile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_in_Cr IS NOT NULL
),
decile_agg AS (
  SELECT
    City,
    decile,
    COUNT(*) AS cnt,
    SUM(value_cr) AS decile_value_cr
  FROM city_ordered
  GROUP BY City, decile
),
city_totals AS (
  SELECT
    City,
    SUM(cnt) AS total_count,
    SUM(decile_value_cr) AS total_value_cr
  FROM decile_agg
  GROUP BY City
),
decile_cume AS (
  SELECT
    d.City,
    d.decile,
    d.cnt,
    d.decile_value_cr,
    SUM(d.decile_value_cr) OVER (PARTITION BY d.City ORDER BY d.decile ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_value_cr,
    SUM(d.cnt) OVER (PARTITION BY d.City ORDER BY d.decile ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_count
  FROM decile_agg d
)
SELECT
  dc.City,
  dc.decile,
  dc.cnt AS listings_in_decile,
  ROUND(dc.decile_value_cr,4) AS decile_value_cr,
  ROUND(dc.cum_value_cr / NULLIF(ct.total_value_cr,0) * 100,3) AS cum_pct_value,
  ROUND(dc.cum_count / NULLIF(ct.total_count,0) * 100,3) AS cum_pct_listings
FROM decile_cume dc
JOIN city_totals ct USING (City)
ORDER BY City, decile;

/* ---------------------------------------------------------------------------
   2) Price per SQFT vs. Total_Area Non-Linearity (log-log slope & correlation)
   Purpose: test multiplicative relationships by fitting ln(ppsf) ~ ln(area)
--------------------------------------------------------------------------- */
WITH base AS (
  SELECT
    City,
    Price_per_SQFT,
    Total_Area,
    CASE WHEN Price_per_SQFT > 0 AND Total_Area > 0 THEN LOG(Price_per_SQFT) ELSE NULL END AS ln_ppsf,
    CASE WHEN Price_per_SQFT > 0 AND Total_Area > 0 THEN LOG(Total_Area) ELSE NULL END AS ln_area
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Price_per_SQFT IS NOT NULL
    AND Total_Area IS NOT NULL
    AND Price_per_SQFT > 0
    AND Total_Area > 0
),
city_means AS (
  -- per-city means of the log variables
  SELECT
    City,
    AVG(ln_area) AS mean_ln_area,
    AVG(ln_ppsf) AS mean_ln_ppsf,
    COUNT(*) AS n
  FROM base
  GROUP BY City
),
city_sums AS (
  -- sums needed for covariance and variances (no nested window functions)
  SELECT
    b.City,
    SUM( (b.ln_area - cm.mean_ln_area) * (b.ln_ppsf - cm.mean_ln_ppsf) ) AS sum_cov,
    SUM( POWER(b.ln_area - cm.mean_ln_area, 2) ) AS sum_var_x,
    SUM( POWER(b.ln_ppsf - cm.mean_ln_ppsf, 2) ) AS sum_var_y,
    MAX(cm.n) AS n
  FROM base b
  JOIN city_means cm USING (City)
  GROUP BY b.City
)
SELECT
  City,
  n,
  ROUND( (sum_cov / NULLIF(sum_var_x,0)), 6 ) AS log_log_slope,         -- slope = cov / var_x
  ROUND( (sum_cov / NULLIF( SQRT(sum_var_x * sum_var_y), 0 ) ), 6 ) AS log_log_cor -- Pearson r on logs
FROM city_sums
ORDER BY log_log_slope;

/* ---------------------------------------------------------------------------
   3) Area–Price Elasticity Banding (per-city quintiles)
   Purpose: compute log-log elasticity within area bands (uses Total_Area)
--------------------------------------------------------------------------- */
WITH base AS (
  SELECT
    City,
    Total_Area AS area,
    Price_per_SQFT AS ppsf,
    CASE WHEN Total_Area > 0 THEN LOG(Total_Area) ELSE NULL END AS ln_area,
    CASE WHEN Price_per_SQFT > 0 THEN LOG(Price_per_SQFT) ELSE NULL END AS ln_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Total_Area IS NOT NULL
    AND Price_per_SQFT IS NOT NULL
    AND Total_Area > 0
    AND Price_per_SQFT > 0
),
banded AS (
  -- assign each listing to one of 5 area bands within its city
  SELECT
    City,
    area,
    ppsf,
    ln_area,
    ln_ppsf,
    NTILE(5) OVER (PARTITION BY City ORDER BY area) AS area_band
  FROM base
  WHERE ln_area IS NOT NULL AND ln_ppsf IS NOT NULL
),
band_means AS (
  -- per-city & per-area_band means and counts (no nested windows inside aggregates)
  SELECT
    City,
    area_band,
    COUNT(*) AS n,
    AVG(ln_area) AS mean_ln_area,
    AVG(ln_ppsf) AS mean_ln_ppsf
  FROM banded
  GROUP BY City, area_band
),
band_sums AS (
  -- compute sums needed for covariance and variance by joining back to the rows
  SELECT
    b.City,
    b.area_band,
    m.n,
    SUM( (b.ln_area - m.mean_ln_area) * (b.ln_ppsf - m.mean_ln_ppsf) ) AS sum_cov,
    SUM( POWER(b.ln_area - m.mean_ln_area, 2) ) AS sum_var_x
  FROM banded b
  JOIN band_means m
    ON b.City = m.City AND b.area_band = m.area_band
  GROUP BY b.City, b.area_band, m.n
)
SELECT
  City,
  area_band,
  n,
  -- elasticity (log-log slope) = cov / var_x
  ROUND( (sum_cov / NULLIF(sum_var_x,0)), 6) AS elasticity_log_log
FROM band_sums
ORDER BY City, area_band;

/* ---------------------------------------------------------------------------
   4) Locality "Price Skewness" & "Kurtosis"
   Purpose: compute skewness and excess kurtosis of Price_per_SQFT per locality
--------------------------------------------------------------------------- */
WITH loc AS (
  SELECT City, Locality, Price_per_SQFT
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Locality IS NOT NULL
    AND Price_per_SQFT IS NOT NULL
),
loc_means AS (
  -- per-locality count and mean (used as a constant in the next aggregation)
  SELECT
    City,
    Locality,
    COUNT(*) AS n,
    AVG(Price_per_SQFT) AS mean_ppsf
  FROM loc
  GROUP BY City, Locality
),
dev_sums AS (
  -- sum of powers of deviations from the mean (2nd, 3rd, 4th)
  SELECT
    l.City,
    l.Locality,
    m.n,
    m.mean_ppsf,
    SUM( POWER(l.Price_per_SQFT - m.mean_ppsf, 2) ) AS sum2,
    SUM( POWER(l.Price_per_SQFT - m.mean_ppsf, 3) ) AS sum3,
    SUM( POWER(l.Price_per_SQFT - m.mean_ppsf, 4) ) AS sum4
  FROM loc l
  JOIN loc_means m USING (City, Locality)
  GROUP BY l.City, l.Locality, m.n, m.mean_ppsf
)
SELECT
  City,
  Locality,
  n,
  ROUND(mean_ppsf, 2) AS mean_ppsf,
  -- population standard deviation (sd = sqrt(Σ(x-μ)^2 / n))
  ROUND( SQRT( sum2 / NULLIF(n,0) ), 2 ) AS sd_ppsf,
  -- skewness = (Σ(x-μ)^3 / n) / sd^3
  CASE
    WHEN n > 0 AND sum2 > 0 THEN ROUND( ( (sum3 / NULLIF(n,1)) / POWER( SQRT(sum2 / NULLIF(n,0)), 3 ) ), 6)
    ELSE NULL
  END AS skewness,
  -- excess kurtosis = (Σ(x-μ)^4 / n) / sd^4 - 3
  CASE
    WHEN n > 0 AND sum2 > 0 THEN ROUND( ( (sum4 / NULLIF(n,1)) / POWER( SQRT(sum2 / NULLIF(n,0)), 4 ) - 3 ), 6)
    ELSE NULL
  END AS excess_kurtosis
FROM dev_sums
WHERE n >= 8                 -- keep reasonably sized localities
ORDER BY City, skewness DESC;

/* ---------------------------------------------------------------------------
   5) Simpson's Paradox Check: pooled vs within-locality correlation
   Purpose: flag cities where pooled sign differs from within-locality sign
--------------------------------------------------------------------------- */
WITH base AS (
  SELECT
    City,
    Locality,
    Total_Area AS area,
    Price_per_SQFT AS ppsf,
    CASE WHEN Total_Area > 0 THEN LOG(Total_Area) ELSE NULL END AS ln_area,
    CASE WHEN Price_per_SQFT > 0 THEN LOG(Price_per_SQFT) ELSE NULL END AS ln_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL
    AND Locality IS NOT NULL
    AND Total_Area > 0
    AND Price_per_SQFT IS NOT NULL
    AND Price_per_SQFT > 0
),
-- pooled (city-level) means
city_means AS (
  SELECT
    City,
    AVG(ln_area)    AS mean_ln_area_city,
    AVG(ln_ppsf)    AS mean_ln_ppsf_city,
    COUNT(*)        AS city_n
  FROM base
  WHERE ln_area IS NOT NULL AND ln_ppsf IS NOT NULL
  GROUP BY City
),
-- pooled (city-level) covariance / variance sums
pooled_sums AS (
  SELECT
    b.City,
    SUM( (b.ln_area - cm.mean_ln_area_city) * (b.ln_ppsf - cm.mean_ln_ppsf_city) ) AS sum_cov_pooled,
    SUM( POWER(b.ln_area - cm.mean_ln_area_city, 2) ) AS sum_varx_pooled,
    SUM( POWER(b.ln_ppsf - cm.mean_ln_ppsf_city, 2) ) AS sum_vary_pooled,
    MAX(cm.city_n) AS city_n
  FROM base b
  JOIN city_means cm USING (City)
  GROUP BY b.City
),
pooled_agg AS (
  SELECT
    City,
    city_n,
    CASE
      WHEN sum_varx_pooled > 0 AND sum_vary_pooled > 0
      THEN sum_cov_pooled / SQRT(sum_varx_pooled * sum_vary_pooled)
      ELSE NULL
    END AS pooled_corr_log
  FROM pooled_sums
),
-- locality (within-city) means
loc_means AS (
  SELECT
    City,
    Locality,
    AVG(ln_area) AS mean_ln_area_loc,
    AVG(ln_ppsf) AS mean_ln_ppsf_loc,
    COUNT(*)     AS loc_n
  FROM base
  WHERE ln_area IS NOT NULL AND ln_ppsf IS NOT NULL
  GROUP BY City, Locality
),
-- locality covariance/variance sums
loc_sums AS (
  SELECT
    b.City,
    b.Locality,
    lm.loc_n,
    SUM( (b.ln_area - lm.mean_ln_area_loc) * (b.ln_ppsf - lm.mean_ln_ppsf_loc) ) AS sum_cov_loc,
    SUM( POWER(b.ln_area - lm.mean_ln_area_loc, 2) ) AS sum_varx_loc,
    SUM( POWER(b.ln_ppsf - lm.mean_ln_ppsf_loc, 2) ) AS sum_vary_loc
  FROM base b
  JOIN loc_means lm
    ON b.City = lm.City AND b.Locality = lm.Locality
  GROUP BY b.City, b.Locality, lm.loc_n
),
-- compute per-locality correlation and filter thin localities
loc_agg AS (
  SELECT
    City,
    Locality,
    loc_n,
    CASE
      WHEN sum_varx_loc > 0 AND sum_vary_loc > 0
      THEN sum_cov_loc / SQRT(sum_varx_loc * sum_vary_loc)
      ELSE NULL
    END AS loc_corr
  FROM loc_sums
  WHERE loc_n >= 8
),
-- summary of within-locality correlations per city
within_summary AS (
  SELECT
    City,
    AVG(loc_corr) AS avg_loc_corr_unweighted,                         -- simple mean of local correlations
    SUM(loc_corr * loc_n) / NULLIF(SUM(loc_n),0) AS avg_loc_corr_weighted,
    COUNT(*) AS locality_count
  FROM loc_agg
  GROUP BY City
)
SELECT
  p.City,
  ROUND(p.pooled_corr_log,4)           AS pooled_corr_log,
  ROUND(w.avg_loc_corr_unweighted,4)   AS avg_loc_corr_unweighted,
  ROUND(w.avg_loc_corr_weighted,4)     AS avg_loc_corr_weighted,
  w.locality_count,
  CASE
    WHEN p.pooled_corr_log IS NULL OR w.avg_loc_corr_weighted IS NULL THEN 'INSUFFICIENT_DATA'
    WHEN SIGN(p.pooled_corr_log) <> SIGN(w.avg_loc_corr_weighted) THEN 'SIMPSON_RISK'
    ELSE 'CONSISTENT'
  END AS simpson_flag
FROM pooled_agg p
LEFT JOIN within_summary w ON w.City = p.City
ORDER BY simpson_flag DESC, City;