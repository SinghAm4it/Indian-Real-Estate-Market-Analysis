
/*
================================================================================
=  Outlier, Anomaly & Mispricing Detection
=  Various anomaly detection checks: z-score, IQR, cross-metric consistency, Mahalanobis, etc.
================================================================================
*/

/* ---------------------------------------------------------------------------
   1) Z-Score Outlier Detection (City-Level)
   Purpose: find extreme listings by ppsf using z-score within city
--------------------------------------------------------------------------- */
WITH city_stats AS (
  SELECT
    City,
    AVG(Price_per_SQFT) AS mean_ppsf,
    STDDEV_POP(Price_per_SQFT) AS sd_ppsf
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
  GROUP BY City
),
scored AS (
  SELECT
    r.*,
    (r.Price_per_SQFT - s.mean_ppsf) / NULLIF(s.sd_ppsf,0) AS zscore_ppsf
  FROM clean_real_estate r
  JOIN city_stats s USING (City)
)
SELECT
  City,
  Locality,
  Price_in_Cr,
  Price_per_SQFT,
  ROUND(zscore_ppsf,2) AS zscore_ppsf,
  CASE
    WHEN ABS(zscore_ppsf) >= 3 THEN 'extreme_outlier'
    WHEN ABS(zscore_ppsf) BETWEEN 2 AND 3 THEN 'mild_outlier'
    ELSE 'normal'
  END AS flag
FROM scored
ORDER BY ABS(zscore_ppsf) DESC
LIMIT 1000;

/* ---------------------------------------------------------------------------
   2) Locality Outlier Detection (IQR Rule)
   Purpose: Tukey fences per locality to flag high/low outliers
--------------------------------------------------------------------------- */
WITH loc_quart AS (
  SELECT
    City,
    Locality,
    Price_per_SQFT,
    NTILE(4) OVER (PARTITION BY City, Locality ORDER BY Price_per_SQFT) AS quartile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Price_per_SQFT IS NOT NULL
),
iqr_calc AS (
  SELECT
    City,
    Locality,
    MAX(CASE WHEN quartile=3 THEN Price_per_SQFT END) AS q3,
    MIN(CASE WHEN quartile=1 THEN Price_per_SQFT END) AS q1
  FROM loc_quart
  GROUP BY City, Locality
),
joined AS (
  SELECT
    r.City,
    r.Locality,
    r.Price_per_SQFT,
    i.q1,
    i.q3,
    (i.q3 - i.q1) AS iqr
  FROM clean_real_estate r
  JOIN iqr_calc i USING (City, Locality)
)
SELECT
  City,
  Locality,
  Price_per_SQFT,
  ROUND(q1 - 1.5*iqr,2) AS lower_bound,
  ROUND(q3 + 1.5*iqr,2) AS upper_bound,
  CASE
    WHEN Price_per_SQFT < q1 - 1.5*iqr THEN 'low_outlier'
    WHEN Price_per_SQFT > q3 + 1.5*iqr THEN 'high_outlier'
    ELSE 'normal'
  END AS flag
FROM joined
WHERE iqr > 0
ORDER BY City, Locality, Price_per_SQFT;

/* ---------------------------------------------------------------------------
   3) Cross-Metric Consistency Check: recompute ppsf from Price_in_Cr and Total_Area
   Purpose: detect mismatches between reported ppsf and computed ppsf
--------------------------------------------------------------------------- */
SELECT
  City,
  Locality,
  Price_in_Cr,
  Total_Area,
  Price_per_SQFT,
  ROUND((Price_in_Cr*10000000)/NULLIF(Total_Area,0),2) AS recomputed_ppsf,
  ROUND(Price_per_SQFT - (Price_in_Cr*10000000/NULLIF(Total_Area,0)),2) AS diff,
  CASE
    WHEN ABS(Price_per_SQFT - (Price_in_Cr*10000000/NULLIF(Total_Area,0))) > 500 THEN 'inconsistent'
    ELSE 'consistent'
  END AS consistency_flag
FROM clean_real_estate
WHERE Price_in_Cr IS NOT NULL AND Total_Area IS NOT NULL AND Price_per_SQFT IS NOT NULL
ORDER BY ABS(diff) DESC
LIMIT 500;

/* ---------------------------------------------------------------------------
   4) Mispricing by City Median
   Purpose: simple median-based overpriced/underpriced flag relative to city median
--------------------------------------------------------------------------- */
WITH ppsf_ranked AS (
    SELECT
        City,
        Locality,
        Price_per_SQFT,
        ROW_NUMBER() OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS rn,
        COUNT(*) OVER (PARTITION BY City) AS n
    FROM clean_real_estate
    WHERE City IS NOT NULL
      AND Price_per_SQFT IS NOT NULL
),
city_median AS (
    SELECT
        City,
        -- median for odd/even n
        CASE
            WHEN MOD(n, 2) = 1 THEN 
                MAX(CASE WHEN rn = (n + 1) / 2 THEN Price_per_SQFT END)
            ELSE 
                (
                    MAX(CASE WHEN rn =  n/2      THEN Price_per_SQFT END) +
                    MAX(CASE WHEN rn = (n/2) + 1 THEN Price_per_SQFT END)
                ) / 2
        END AS median_ppsf
    FROM ppsf_ranked
    GROUP BY City, n
)
-- Step 2: Join back and compute flags
SELECT
    r.City,
    r.Locality,
    r.Price_per_SQFT,
    c.median_ppsf,
    ROUND(r.Price_per_SQFT - c.median_ppsf, 2) AS diff_ppsf,
    CASE
        WHEN r.Price_per_SQFT > 1.5 * c.median_ppsf THEN 'overpriced'
        WHEN r.Price_per_SQFT < 0.5 * c.median_ppsf THEN 'underpriced'
        ELSE 'normal'
    END AS flag
FROM clean_real_estate r
JOIN city_median c USING (City)
WHERE r.Price_per_SQFT IS NOT NULL
ORDER BY ABS(diff_ppsf) DESC;

/* ---------------------------------------------------------------------------
   5) Locality Outlier Density
   Purpose: fraction of listings in each locality that are z-outliers (|z|>2)
--------------------------------------------------------------------------- */
WITH zscores AS (
  SELECT
    City,
    Locality,
    (Price_per_SQFT - AVG(Price_per_SQFT) OVER (PARTITION BY City, Locality))
    / NULLIF(STDDEV_POP(Price_per_SQFT) OVER (PARTITION BY City, Locality),0) AS z
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Locality IS NOT NULL AND Price_per_SQFT IS NOT NULL
)
SELECT
  City,
  Locality,
  COUNT(*) AS n,
  SUM(CASE WHEN ABS(z) > 2 THEN 1 ELSE 0 END) AS outlier_count,
  ROUND(SUM(CASE WHEN ABS(z)>2 THEN 1 ELSE 0 END)/COUNT(*),3) AS outlier_rate
FROM zscores
GROUP BY City, Locality
ORDER BY outlier_rate DESC;

/* ---------------------------------------------------------------------------
   6) Price-Size Misalignment (log-log expected ppsf from Total_Area)
   Purpose: detect listings that deviate strongly from city's log-log trend
--------------------------------------------------------------------------- */
WITH city_trend AS (
  SELECT
    City,
    SUM(LOG(Total_Area) * LOG(Price_per_SQFT)) AS sum_xy,
    SUM(LOG(Total_Area)) AS sum_x,
    SUM(LOG(Price_per_SQFT)) AS sum_y,
    SUM(POWER(LOG(Total_Area),2)) AS sum_x2,
    COUNT(*) AS n
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT>0 AND Total_Area>0
  GROUP BY City
),
coeffs AS (
  SELECT
    City,
    (n*sum_xy - sum_x*sum_y)/(n*sum_x2 - POWER(sum_x,2)) AS slope,
    (sum_y - ((n*sum_xy - sum_x*sum_y)/(n*sum_x2 - POWER(sum_x,2))) * sum_x)/n AS intercept
  FROM city_trend
),
pred AS (
  SELECT
    r.City,
    r.Locality,
    r.Price_per_SQFT,
    r.Total_Area,
    ROUND(EXP(c.intercept + c.slope*LOG(r.Total_Area)),2) AS expected_ppsf,
    ROUND(r.Price_per_SQFT - EXP(c.intercept + c.slope*LOG(r.Total_Area)),2) AS diff
  FROM clean_real_estate r
  JOIN coeffs c USING (City)
  WHERE r.Price_per_SQFT>0 AND r.Total_Area>0
)
SELECT *,
  CASE
    WHEN ABS(diff) > 0.5*expected_ppsf THEN 'misaligned'
    ELSE 'aligned'
  END AS flag
FROM pred
ORDER BY ABS(diff) DESC
LIMIT 500;

/* ---------------------------------------------------------------------------
   7) Multivariate Outlier Score (Mahalanobis approx on ppsf & Total_Area)
   Purpose: find listings that are jointly extreme in price-per-sqft and size
--------------------------------------------------------------------------- */
WITH stats AS (
    SELECT
        City,
        COUNT(*) AS n,
        AVG(Price_per_SQFT) AS mean_ppsf,
        AVG(Total_Area) AS mean_area,
        SUM(Price_per_SQFT * Price_per_SQFT) AS sum_ppsf2,
        SUM(Total_Area * Total_Area) AS sum_area2,
        SUM(Price_per_SQFT * Total_Area) AS sum_ppsf_area
    FROM clean_real_estate
    WHERE City IS NOT NULL
      AND Price_per_SQFT IS NOT NULL
      AND Total_Area IS NOT NULL
    GROUP BY City
),
cov_calc AS (
    SELECT
        City,
        mean_ppsf,
        mean_area,
        -- population variances
        (sum_ppsf2 / n) - POWER(mean_ppsf,2) AS var_ppsf,
        (sum_area2 / n) - POWER(mean_area,2) AS var_area,
        -- population covariance
        (sum_ppsf_area / n) - (mean_ppsf * mean_area) AS cov_pa
    FROM stats
),
scores AS (
    SELECT
        r.City,
        r.Locality,
        r.Price_per_SQFT,
        r.Total_Area,
        s.mean_ppsf,
        s.mean_area,
        s.var_ppsf,
        s.var_area,
        s.cov_pa,
        -- 2D Mahalanobis Distance formula
        SQRT(
            (1 / (s.var_ppsf * s.var_area - POWER(s.cov_pa, 2))) *
            (
                s.var_area * POWER(r.Price_per_SQFT - s.mean_ppsf, 2)
                - 2 * s.cov_pa * (r.Price_per_SQFT - s.mean_ppsf) * (r.Total_Area - s.mean_area)
                + s.var_ppsf * POWER(r.Total_Area - s.mean_area, 2)
            )
        ) AS mahal_dist
    FROM clean_real_estate r
    JOIN cov_calc s USING (City)
)
SELECT
    City,
    Locality,
    ROUND(mahal_dist, 3) AS mahal_dist,
    CASE
        WHEN mahal_dist > 4 THEN 'multivariate_outlier'
        ELSE 'normal'
    END AS flag
FROM scores
ORDER BY mahal_dist DESC;

/* ---------------------------------------------------------------------------
   8) Locality Value Density (suspiciously high/low volume)
   Purpose: detect localities with disproportionate listing share in the city
--------------------------------------------------------------------------- */
WITH city_total AS (
  SELECT City, COUNT(*) AS total FROM clean_real_estate GROUP BY City
),
loc_total AS (
  SELECT City, Locality, COUNT(*) AS loc_count FROM clean_real_estate GROUP BY City, Locality
)
SELECT
  l.City,
  l.Locality,
  l.loc_count,
  c.total AS city_total,
  ROUND((l.loc_count / NULLIF(c.total,0)) * 100,2) AS pct_share,
  CASE
    WHEN l.loc_count > 0.5 * c.total THEN 'suspiciously_high'
    WHEN l.loc_count < 0.02 * c.total THEN 'too_low'
    ELSE 'normal'
  END AS volume_flag
FROM loc_total l
JOIN city_total c USING (City)
ORDER BY volume_flag DESC, pct_share DESC;

/* ---------------------------------------------------------------------------
   9) Top & Bottom 1% Value Anomalies (ppsf)
   Purpose: list most extreme 1% tails by Price_per_SQFT
--------------------------------------------------------------------------- */
WITH ranked AS (
  SELECT
    City,
    Locality,
    Price_per_SQFT,
    NTILE(100) OVER (PARTITION BY City ORDER BY Price_per_SQFT) AS pctile
  FROM clean_real_estate
  WHERE City IS NOT NULL AND Price_per_SQFT IS NOT NULL
)
SELECT
  City,
  Locality,
  Price_per_SQFT,
  CASE
    WHEN pctile <= 1 THEN 'bottom_1_percent'
    WHEN pctile >= 99 THEN 'top_1_percent'
    ELSE 'normal'
  END AS extreme_flag
FROM ranked
WHERE pctile <= 1 OR pctile >= 99
ORDER BY City, Price_per_SQFT DESC;
