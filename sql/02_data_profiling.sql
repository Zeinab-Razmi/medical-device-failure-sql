/* =====================================================================
   STEP 2 - DATA PROFILING:
   ===================================================================== */

-- 2.1 Size of the dataset (expected 4149)
SELECT COUNT(*) AS total_rows FROM raw_devices;

-- 2.2 Missing / blank values per column
SELECT
  COUNT(*) FILTER (WHERE NULLIF(TRIM(device_id),'')             IS NULL) AS miss_device_id,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(device_type),'')           IS NULL) AS miss_device_type,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(purchase_date),'')         IS NULL) AS miss_purchase_date,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(age),'')                   IS NULL) AS miss_age,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(manufacturer),'')          IS NULL) AS miss_manufacturer,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(model),'')                 IS NULL) AS miss_model,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(country),'')               IS NULL) AS miss_country,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(maintenance_cost),'')      IS NULL) AS miss_cost,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(downtime),'')              IS NULL) AS miss_downtime,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(maintenance_frequency),'') IS NULL) AS miss_frequency,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(failure_event_count),'')   IS NULL) AS miss_failures,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(maintenance_class),'')     IS NULL) AS miss_class,
  COUNT(*) FILTER (WHERE NULLIF(TRIM(maintenance_report),'')    IS NULL) AS miss_report
FROM raw_devices;

-- 2.3 Duplicates: whole rows, and the same Device_ID more than once
SELECT COUNT(*) - COUNT(DISTINCT raw_devices.*) AS exact_duplicate_rows FROM raw_devices;

SELECT device_id, COUNT(*) AS times
FROM raw_devices GROUP BY device_id HAVING COUNT(*) > 1;

-- 2.4 Does every Device_ID follow the pattern MD + 5 digits?
SELECT COUNT(*) AS bad_device_ids
FROM raw_devices WHERE device_id !~ '^MD[0-9]{5}$';

-- 2.5 Category columns: look for spelling / case / spacing variants
SELECT device_type,  COUNT(*) FROM raw_devices GROUP BY 1 ORDER BY 1;
SELECT manufacturer, COUNT(*) FROM raw_devices GROUP BY 1 ORDER BY 1;
SELECT country,      COUNT(*) FROM raw_devices GROUP BY 1 ORDER BY 1;
SELECT model,        COUNT(*) FROM raw_devices GROUP BY 1 ORDER BY 1;
SELECT maintenance_class, COUNT(*) FROM raw_devices GROUP BY 1 ORDER BY 1;

-- 2.6 Is the same model name used by several manufacturers?

SELECT model, COUNT(DISTINCT manufacturer) AS manufacturers_using_it
FROM raw_devices GROUP BY model ORDER BY model;

-- 2.7 Are the numeric columns really numbers?
SELECT
  COUNT(*) FILTER (WHERE maintenance_cost      !~ '^-?[0-9]+(\.[0-9]+)?$') AS bad_cost,
  COUNT(*) FILTER (WHERE downtime              !~ '^-?[0-9]+(\.[0-9]+)?$') AS bad_downtime,
  COUNT(*) FILTER (WHERE age                   !~ '^[0-9]+$')              AS bad_age,
  COUNT(*) FILTER (WHERE maintenance_frequency !~ '^[0-9]+$')              AS bad_frequency,
  COUNT(*) FILTER (WHERE failure_event_count   !~ '^[0-9]+$')              AS bad_failures
FROM raw_devices;

-- 2.8 Value ranges
SELECT
  MIN(maintenance_cost::NUMERIC) AS min_cost,   MAX(maintenance_cost::NUMERIC) AS max_cost,
  MIN(downtime::NUMERIC)         AS min_down,   MAX(downtime::NUMERIC)         AS max_down,
  MIN(age::INT)                  AS min_age,    MAX(age::INT)                  AS max_age,
  MIN(failure_event_count::INT)  AS min_fail,   MAX(failure_event_count::INT)  AS max_fail,
  MIN(purchase_date::DATE)       AS first_purchase, MAX(purchase_date::DATE)   AS last_purchase
FROM raw_devices;

-- 2.9 How many negative maintenance costs?
SELECT COUNT(*) AS negative_costs
FROM raw_devices WHERE maintenance_cost::NUMERIC < 0;

-- 2.10 Too many decimals? (money should have 2)
SELECT maintenance_cost, downtime FROM raw_devices LIMIT 5;

-- 2.11 Consistency check: is Age = 2025 - purchase year?
SELECT (2025 - EXTRACT(YEAR FROM purchase_date::DATE)) - age::INT AS difference,
       COUNT(*)
FROM raw_devices GROUP BY 1 ORDER BY 1;

-- 2.12 Free-text report problems
--      a) repeated words, e.g. "Component component upgrade"
SELECT COUNT(*) AS reports_with_repeated_word
FROM raw_devices WHERE maintenance_report ~* '\m(\w+)\s+\1\M';

SELECT maintenance_report
FROM raw_devices WHERE maintenance_report ~* '\m(\w+)\s+\1\M' LIMIT 5;

--      b) sentences starting with a lowercase letter
SELECT COUNT(*) AS reports_starting_lowercase
FROM raw_devices WHERE maintenance_report ~ '^[a-z]';

--      c) the report hides useful categories inside text
SELECT maintenance_report FROM raw_devices ORDER BY RANDOM() LIMIT 15;

-- 2.13 Outlier preview with the IQR rule
WITH q AS (
  SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY maintenance_cost::NUMERIC) AS q1,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY maintenance_cost::NUMERIC) AS q3
  FROM raw_devices)
SELECT q1, q3, q3 - q1 AS iqr,
       q3 + 1.5 * (q3 - q1) AS upper_limit,
       (SELECT COUNT(*) FROM raw_devices, q q2
         WHERE maintenance_cost::NUMERIC > q2.q3 + 1.5 * (q2.q3 - q2.q1)) AS high_cost_outliers
FROM q;
