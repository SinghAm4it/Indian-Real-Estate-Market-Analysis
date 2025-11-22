
/*
================================================================================
=  Luxury, Inequality & Market Concentration
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) Luxury Index per City
   Purpose: combine top-decile share and intensity into a single luxury index
--------------------------------------------------------------------------- */
WITH city_pct AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
city_top AS (
  SELECT
    City,
    COUNT(*) AS total_listings,
    SUM(CASE WHEN pctile >= 90 THEN 1 ELSE 0 END) AS top10_listings,
    AVG(CASE WHEN pctile >= 90 THEN Price_per_SQFT END) AS avg_top10_ppsf,
    AVG(Price_per_SQFT) AS city_avg_ppsf
  FROM city_pct
  GROUP BY City
)
SELECT
  City,
  total_listings,
  top10_listings,
  ROUND( (top10_listings / NULLIF(total_listings,0)) * 100,2) AS pct_top10_listings,
  ROUND(avg_top10_ppsf,2) AS avg_top10_ppsf,
  ROUND(city_avg_ppsf,2) AS city_avg_ppsf,
  ROUND( (top10_listings / NULLIF(total_listings,0)) * (avg_top10_ppsf / NULLIF(city_avg_ppsf,0)) * 100,3) AS luxury_index
FROM city_top
ORDER BY luxury_index DESC;

/* ---------------------------------------------------------------------------
   2) Locality Concentration Index (HHI) - listings & value based
   Purpose: compute HHI on listing share and market-value share
--------------------------------------------------------------------------- */
WITH loc_shares AS (
  SELECT
    City,
    Locality,
    COUNT(*) AS listings,
    SUM(Price_in_Cr) AS total_value_cr
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL
  GROUP BY City, Locality
),
city_totals AS (
  SELECT
    City,
    SUM(listings) AS city_listings,
    SUM(total_value_cr) AS city_value_cr
  FROM loc_shares
  GROUP BY City
),
loc_shares_pct AS (
  SELECT
    l.City,
    l.Locality,
    l.listings,
    l.total_value_cr,
    l.listings / NULLIF(ct.city_listings,0) AS listings_share,
    l.total_value_cr / NULLIF(ct.city_value_cr,0) AS value_share
  FROM loc_shares l
  JOIN city_totals ct USING (City)
)
SELECT
  City,
  ROUND(SUM(POW(listings_share,2)) * 10000,3) AS hhi_listings,
  ROUND(SUM(POW(value_share,2)) * 10000,3) AS hhi_value,
  COUNT(*) AS num_localities
FROM loc_shares_pct
GROUP BY City
ORDER BY hhi_value DESC;

/* ---------------------------------------------------------------------------
   3) City Price Dispersion Pack: Gini, Theil T, Atkinson (eps=0.5), Variance
   Purpose: multi-metric inequality report per city (ppsf)
--------------------------------------------------------------------------- */
WITH city_data AS (
  SELECT City, Locality, Price_per_SQFT
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
ranked AS (
  SELECT
    City,
    Price_per_SQFT,
    ROW_NUMBER() OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS rn,
    COUNT(*) OVER (PARTITION BY City) AS n,
    SUM(Price_per_SQFT) OVER (PARTITION BY City) AS sum_x,
    AVG(Price_per_SQFT) OVER (PARTITION BY City) AS mean_x,
    SUM(POWER(Price_per_SQFT,2)) OVER (PARTITION BY City) AS sum_x2
  FROM city_data
),
gini_calc AS (
  SELECT
    City,
    n,
    (2.0 * SUM(rn * Price_per_SQFT) OVER (PARTITION BY City)) AS two_sum_ix,
    SUM(Price_per_SQFT) OVER (PARTITION BY City) AS Sx
  FROM ranked
),
gini_final AS (
  SELECT
    City,
    n,
    Sx,
    ( (two_sum_ix / (n * Sx)) - ( (n + 1.0) / n ) ) AS gini_coeff
  FROM gini_calc
  GROUP BY City, n, two_sum_ix, Sx
),
theil_calc AS (
  SELECT
    City,
    SUM( (Price_per_SQFT / NULLIF(mean_x,0)) * LOG(Price_per_SQFT / NULLIF(mean_x,1e-12)) ) OVER (PARTITION BY City) / MAX(n) OVER (PARTITION BY City) AS theil_t
  FROM ranked
),
theil_final AS (
  SELECT City, AVG(theil_t) AS theil_t FROM theil_calc GROUP BY City
),
atkinson_calc AS (
  SELECT
    City,
    AVG( POWER(Price_per_SQFT, 1 - 0.5) ) OVER (PARTITION BY City) AS mean_power,
    AVG(Price_per_SQFT) OVER (PARTITION BY City) AS mean_x
  FROM city_data
),
atkinson_final AS (
  SELECT DISTINCT
    City,
    1 - ( POWER(mean_power, 1.0 / (1 - 0.5)) / NULLIF(mean_x,0) ) AS atkinson_eps_0_5
  FROM atkinson_calc
),
city_variance AS (
  SELECT
    City,
    VAR_POP(Price_per_SQFT) AS total_var
  FROM city_data
  GROUP BY City
),
ineq as(
	SELECT
	  g.City,
	  ROUND(g.gini_coeff,4) AS gini,
	  ROUND(t.theil_t,6) AS theil_t,
	  ROUND(a.atkinson_eps_0_5,6) AS atkinson_eps_0_5,
	  ROUND(cv.total_var,6) AS total_variance
	FROM gini_final g
	LEFT JOIN theil_final t ON t.City = g.City
	LEFT JOIN atkinson_final a ON a.City = g.City
	LEFT JOIN city_variance cv ON cv.City = g.City
	ORDER BY g.gini_coeff DESC
),
stats AS (
    SELECT
        MIN(gini)              AS gini_min,
        MAX(gini)              AS gini_max,
        MIN(theil_t)           AS theil_min,
        MAX(theil_t)           AS theil_max,
        MIN(atkinson_eps_0_5)  AS atk_min,
        MAX(atkinson_eps_0_5)  AS atk_max,
        MIN(total_variance)    AS var_min,
        MAX(total_variance)    AS var_max
    FROM ineq
),
normalized AS (
    SELECT
        i.City,
        i.gini,
        i.theil_t,
        i.atkinson_eps_0_5,
        i.total_variance,
        (i.gini -  s.gini_min) /
            NULLIF(s.gini_max - s.gini_min, 0)          AS gini_norm,
        (i.theil_t - s.theil_min) /
            NULLIF(s.theil_max - s.theil_min, 0)        AS theil_norm,
        (i.atkinson_eps_0_5 - s.atk_min) /
            NULLIF(s.atk_max - s.atk_min, 0)            AS atk_norm,
        (i.total_variance - s.var_min) /
            NULLIF(s.var_max - s.var_min, 0)            AS var_norm
    FROM ineq i
    CROSS JOIN stats s
)
SELECT
    City,
    gini,
    theil_t,
    atkinson_eps_0_5,
    total_variance,
    ROUND(gini_norm, 4)  AS gini_norm,
    ROUND(theil_norm, 4) AS theil_norm,
    ROUND(atk_norm, 4)   AS atkinson_norm,
    ROUND(var_norm, 4)   AS variance_norm,
    ROUND(
        100 * (
              0.30 * gini_norm
            + 0.25 * theil_norm
            + 0.25 * atk_norm
            + 0.20 * var_norm
        )
    , 2) AS inequality_score_100
FROM normalized
ORDER BY inequality_score_100 DESC;

/* ---------------------------------------------------------------------------
   4) Property-type Entropy (Shannon)
   Purpose: how diverse is the property-type mix per city
--------------------------------------------------------------------------- */
WITH type_shares AS (
  SELECT
    City,
    Property_Type,
    COUNT(*) AS cnt
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Property_Type IS NOT NULL
  GROUP BY City, Property_Type
),
city_tot AS (
  SELECT City, SUM(cnt) AS total_cnt FROM type_shares GROUP BY City
),
shares AS (
  SELECT
    t.City,
    t.Property_Type,
    t.cnt,
    t.cnt / NULLIF(ct.total_cnt,0) AS p
  FROM type_shares t
  JOIN city_tot ct USING (City)
)
SELECT
  City,
  ROUND(-SUM( p * LOG(p) ),6) AS entropy_natlog,
  ROUND(-SUM( p * LOG(p) ) / NULLIF(LOG(COUNT(DISTINCT Property_Type)),0),6) AS entropy_normalized,
  COUNT(DISTINCT Property_Type) AS type_count
FROM shares
GROUP BY City
ORDER BY entropy_natlog DESC;

/* ---------------------------------------------------------------------------
   5) Tail Thickness via Hill Estimator (ppsf, top-10%)
   Purpose: estimate tail index alpha for high-end prices
--------------------------------------------------------------------------- */
WITH city_pct AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
city_tail AS (
  SELECT City, Price_per_SQFT
  FROM city_pct
  WHERE pctile >= 90
),
tail_stats AS (
  SELECT
    City,
    COUNT(*) AS k,
    MIN(Price_per_SQFT) AS x_k
  FROM city_tail
  GROUP BY City
),
hill_calc AS (
  SELECT
    t.City,
    t.k,
    t.x_k,
    AVG(LOG(ct.Price_per_SQFT / NULLIF(t.x_k,0))) AS mean_log_ratio
  FROM city_tail ct
  JOIN tail_stats t ON ct.City = t.City
  GROUP BY t.City, t.k, t.x_k
)
SELECT
  City,
  k AS tail_count,
  x_k AS tail_threshold_ppsf,
  ROUND(mean_log_ratio,6) AS mean_log_ratio,
  CASE WHEN mean_log_ratio > 0 THEN ROUND(1.0 / mean_log_ratio,4) ELSE NULL END AS hill_tail_index_alpha
FROM hill_calc
ORDER BY hill_tail_index_alpha ASC;

/* ---------------------------------------------------------------------------
   6) Top-10% Share of Total Market Value (Price_in_Cr)
   Purpose: what share of market value sits in the top 10% by price
--------------------------------------------------------------------------- */
WITH city_pct AS (
  SELECT
    City,
    Price_in_Cr,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_in_Cr) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_in_Cr IS NOT NULL
),
city_values AS (
  SELECT
    City,
    SUM(Price_in_Cr) AS total_value_cr,
    SUM(CASE WHEN pctile >= 90 THEN Price_in_Cr ELSE 0 END) AS top10_value_cr,
    SUM(CASE WHEN pctile >= 90 THEN 1 ELSE 0 END) AS top10_count,
    COUNT(*) AS total_count
  FROM city_pct
  GROUP BY City
)
SELECT
  City,
  total_value_cr,
  top10_value_cr,
  top10_count,
  ROUND((top10_value_cr / NULLIF(total_value_cr,0)) * 100,3) AS pct_top10_value,
  ROUND((top10_value_cr / NULLIF(top10_count,1)) ,3) AS avg_top10_price_cr
FROM city_values
ORDER BY pct_top10_value DESC;

/* ---------------------------------------------------------------------------
   7) City-wise Density & Spread (IQR & MAD approximations)
   Purpose: robust spread measures to complement mean/stdev
--------------------------------------------------------------------------- */
WITH city_ppsf AS (
  SELECT City, Price_per_SQFT
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
percentiles AS (
  SELECT
    City,
    Price_per_SQFT,
    NTILE(4) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS quartile,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile100
  FROM city_ppsf
),
iqr_calc AS (
  SELECT
    City,
    MAX(CASE WHEN quartile = 3 THEN Price_per_SQFT END) AS q3_approx,
    MIN(CASE WHEN quartile = 1 THEN Price_per_SQFT END) AS q1_approx,
    COUNT(*) AS n
  FROM percentiles
  GROUP BY City
),
median_calc AS (
  -- approximate median as average of the middle ~10% band (pctile 45..55)
  SELECT
    City,
    AVG(CASE WHEN pctile100 BETWEEN 45 AND 55 THEN Price_per_SQFT END) AS median_approx
  FROM percentiles
  GROUP BY City
),
mad_prep AS (
  -- keep pctile100 here so we can filter the middle band when computing MAD
  SELECT
    p.City,
    p.Price_per_SQFT,
    p.pctile100,
    ABS(p.Price_per_SQFT - m.median_approx) AS abs_dev
  FROM percentiles p
  JOIN median_calc m USING (City)
),
mad_calc AS (
  -- approximate MAD as average absolute deviation of the middle band (pctile 45..55)
  SELECT
    City,
    AVG(CASE WHEN pctile100 BETWEEN 45 AND 55 THEN abs_dev END) AS mad_approx
  FROM mad_prep
  GROUP BY City
)
SELECT
  i.City,
  i.n AS listings,
  ROUND(i.q3_approx - i.q1_approx,2) AS iqr_approx,
  ROUND(m.median_approx,2) AS median_ppsf_approx,
  ROUND(mc.mad_approx,2) AS mad_approx
FROM iqr_calc i
LEFT JOIN median_calc m ON m.City = i.City
LEFT JOIN mad_calc mc ON mc.City = i.City
ORDER BY i.q3_approx - i.q1_approx DESC;
