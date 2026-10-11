/* =====================================================================
   STEP 3 - DATA CLEANING
   Pipeline:  raw_devices  ->  stg_devices  ->  devices_clean

   Problems found in step 2 and how we handle them:
     1. All columns are text                 -> convert to real types
     2. Negative maintenance costs (105)      -> set to NULL + flag row
     3. 6-decimal money / hours               -> round to 2 decimals
     4. Repeated words in reports ("Component component upgrade")
                                              -> remove the repeat
     5. Reports starting with lowercase       -> capitalise first letter
     6. Issue + action hidden in free text    -> extract into columns
     7. Maintenance_Class is just 1/2/3       -> add readable label
     8. Extreme costs / downtime              -> FLAG (not delete) outliers
     + Safety checks even if the data looks clean now:
       trim spaces, blanks -> NULL, duplicate IDs, Age vs purchase date
   ===================================================================== */

-- ---------------------------------------------------------------
-- 3.0 Cleaning log: every step writes how many rows it touched
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS cleaning_log;
CREATE TABLE cleaning_log (
    step_no      SERIAL PRIMARY KEY,
    step_name    TEXT,
    rows_changed INTEGER,
    logged_at    TIMESTAMP DEFAULT NOW()
);

-- ---------------------------------------------------------------
-- 3.1 Working copy, with spaces trimmed and blanks turned into NULL
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS stg_devices;
CREATE TABLE stg_devices AS
SELECT
    NULLIF(UPPER(TRIM(device_id)), '')            AS device_id,
    NULLIF(TRIM(device_type), '')                 AS device_type,
    NULLIF(TRIM(purchase_date), '')               AS purchase_date,
    NULLIF(TRIM(age), '')                         AS age,
    NULLIF(TRIM(manufacturer), '')                AS manufacturer,
    NULLIF(TRIM(model), '')                       AS model,
    NULLIF(TRIM(country), '')                     AS country,
    NULLIF(TRIM(maintenance_cost), '')            AS maintenance_cost,
    NULLIF(TRIM(downtime), '')                    AS downtime,
    NULLIF(TRIM(maintenance_frequency), '')       AS maintenance_frequency,
    NULLIF(TRIM(failure_event_count), '')         AS failure_event_count,
    NULLIF(TRIM(maintenance_class), '')           AS maintenance_class,
    NULLIF(REGEXP_REPLACE(TRIM(maintenance_report), '\s+', ' ', 'g'), '') AS maintenance_report
FROM raw_devices;

INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Copied raw data, trimmed spaces, blanks -> NULL', COUNT(*) FROM stg_devices;

-- ---------------------------------------------------------------
-- 3.2 Remove duplicate Device_IDs (keep the first one)
-- ---------------------------------------------------------------
WITH ranked AS (
    SELECT ctid, ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY ctid) AS rn
    FROM stg_devices
), del AS (
    DELETE FROM stg_devices WHERE ctid IN (SELECT ctid FROM ranked WHERE rn > 1)
    RETURNING 1
)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Removed duplicate Device_IDs', COUNT(*) FROM del;

-- ---------------------------------------------------------------
-- 3.3 Fix the free-text report
-- ---------------------------------------------------------------
-- a) remove immediately repeated words: "Component component upgrade" -> "Component upgrade"
WITH u AS (
    UPDATE stg_devices
    SET maintenance_report = REGEXP_REPLACE(maintenance_report, '\m(\w+)\s+\1\M', '\1', 'gi')
    WHERE maintenance_report ~* '\m(\w+)\s+\1\M'
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Report: removed repeated words', COUNT(*) FROM u;

-- b) capitalise the first letter
WITH u AS (
    UPDATE stg_devices
    SET maintenance_report = UPPER(LEFT(maintenance_report, 1)) || SUBSTRING(maintenance_report FROM 2)
    WHERE maintenance_report ~ '^[a-z]'
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Report: capitalised first letter', COUNT(*) FROM u;

-- ---------------------------------------------------------------
-- 3.4 Final clean table with proper data types
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS devices_clean CASCADE;
CREATE TABLE devices_clean (
    device_id              VARCHAR(10) PRIMARY KEY,
    device_type            VARCHAR(50)  NOT NULL,
    manufacturer           VARCHAR(50)  NOT NULL,
    model                  VARCHAR(30),
    country                VARCHAR(50),
    purchase_date          DATE,
    purchase_year          INTEGER,
    age_years              INTEGER,
    maintenance_cost       NUMERIC(10,2),
    downtime_hours         NUMERIC(6,2),
    maintenance_frequency  INTEGER,
    failure_event_count    INTEGER,
    maintenance_class      INTEGER,
    severity_level         VARCHAR(10),
    maintenance_report     TEXT,
    report_category        VARCHAR(40),
    issue_type             VARCHAR(40),
    action_taken           VARCHAR(40),
    -- quality flags: we FLAG suspicious values instead of deleting rows
    is_cost_outlier        BOOLEAN DEFAULT FALSE,
    is_downtime_outlier    BOOLEAN DEFAULT FALSE,
    dq_issue               TEXT
);

INSERT INTO devices_clean (
    device_id, device_type, manufacturer, model, country,
    purchase_date, purchase_year, age_years,
    maintenance_cost, downtime_hours, maintenance_frequency,
    failure_event_count, maintenance_class, maintenance_report)
SELECT
    device_id,
    device_type,
    manufacturer,
    model,
    country,
    purchase_date::DATE,
    EXTRACT(YEAR FROM purchase_date::DATE)::INT,
    age::INT,
    ROUND(maintenance_cost::NUMERIC, 2),
    ROUND(downtime::NUMERIC, 2),
    maintenance_frequency::INT,
    failure_event_count::INT,
    maintenance_class::INT,
    maintenance_report
FROM stg_devices;
-- Why no INITCAP() on device_type? Step 2.5 showed the 6 names are already
-- consistent, and INITCAP would damage acronyms: "CT Scanner" -> "Ct Scanner".
-- Always check a cleaning function doesn't create new problems!

INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Converted to proper data types, rounded to 2 decimals', COUNT(*) FROM devices_clean;

-- ---------------------------------------------------------------
-- 3.5 Negative maintenance cost is impossible -> NULL + flag
-- ---------------------------------------------------------------
WITH u AS (
    UPDATE devices_clean
    SET maintenance_cost = NULL,
        dq_issue = 'Negative maintenance cost removed'
    WHERE maintenance_cost < 0
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Negative maintenance cost set to NULL', COUNT(*) FROM u;

-- ---------------------------------------------------------------
-- 3.6 Consistency check: Age must equal 2025 - purchase year
--     (the dataset was published in 2025)
-- ---------------------------------------------------------------
WITH u AS (
    UPDATE devices_clean
    SET dq_issue = CONCAT_WS('; ', dq_issue, 'Age does not match purchase date')
    WHERE age_years <> 2025 - purchase_year
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Flagged Age / purchase date mismatch', COUNT(*) FROM u;

-- ---------------------------------------------------------------
-- 3.7 Readable severity label for Maintenance_Class
--     Step 2 shows cost and downtime rise from class 1 to class 3,
--     so we read the classes as Low / Medium / High severity.
-- ---------------------------------------------------------------
UPDATE devices_clean
SET severity_level = CASE maintenance_class
                         WHEN 1 THEN 'Low'
                         WHEN 2 THEN 'Medium'
                         WHEN 3 THEN 'High'
                     END;
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Added severity label', COUNT(*) FROM devices_clean WHERE severity_level IS NOT NULL;

-- ---------------------------------------------------------------
-- 3.8 Turn the free-text report into structured columns
--     Reports follow 4 templates:
--       "Routine check completed; <issue> observed during diagnostics. ..."
--       "<issue> caused operational delay; <action> initiated. ..."
--       "System performance degraded due to <issue>; mitigation via <action>. ..."
--       "Component <action> after detecting <issue>; functionality restored. ..."
--     Only the part before the first "." is used (the rest are free tags).
-- ---------------------------------------------------------------
UPDATE devices_clean
SET
  report_category = CASE
      WHEN maintenance_report ILIKE 'Routine check%'               THEN 'Routine check'
      WHEN maintenance_report ILIKE '%caused operational delay%'   THEN 'Operational delay'
      WHEN maintenance_report ILIKE 'System performance degraded%' THEN 'Performance degraded'
      WHEN maintenance_report ILIKE 'Component%after detecting%'   THEN 'Component fault'
      ELSE 'Other' END,
  issue_type = INITCAP(SUBSTRING(LOWER(SPLIT_PART(maintenance_report, '.', 1))
      FROM '(overheating|battery wear|data lag|voltage spike|software crash|abnormal sound|sensor misalignment|circuit failure)')),
  action_taken = COALESCE(
      INITCAP(SUBSTRING(LOWER(SPLIT_PART(maintenance_report, '.', 1))
      FROM '(component upgrade|firmware update|software patch|system reset|recalibration|replacement|inspection)')),
      'None (observation only)');

INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Extracted issue_type from report', COUNT(*) FROM devices_clean WHERE issue_type IS NOT NULL;
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Reports where no issue could be extracted', COUNT(*) FROM devices_clean WHERE issue_type IS NULL;

-- ---------------------------------------------------------------
-- 3.9 Flag outliers with the IQR rule (value > Q3 + 1.5*IQR)
--     We keep them: extreme costs are real events, but analysts
--     should know they exist and can exclude them if needed.
-- ---------------------------------------------------------------
WITH q AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY maintenance_cost) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY maintenance_cost) AS q3
    FROM devices_clean
), u AS (
    UPDATE devices_clean d SET is_cost_outlier = TRUE
    FROM q
    WHERE d.maintenance_cost > q.q3 + 1.5 * (q.q3 - q.q1)
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Flagged maintenance-cost outliers', COUNT(*) FROM u;

WITH q AS (
    SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY downtime_hours) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY downtime_hours) AS q3
    FROM devices_clean
), u AS (
    UPDATE devices_clean d SET is_downtime_outlier = TRUE
    FROM q
    WHERE d.downtime_hours > q.q3 + 1.5 * (q.q3 - q.q1)
    RETURNING 1)
INSERT INTO cleaning_log (step_name, rows_changed)
SELECT 'Flagged downtime outliers', COUNT(*) FROM u;

-- ---------------------------------------------------------------
-- 3.10 Rules the data must follow from now on (constraints)
-- ---------------------------------------------------------------
ALTER TABLE devices_clean
  ADD CONSTRAINT chk_cost      CHECK (maintenance_cost IS NULL OR maintenance_cost >= 0),
  ADD CONSTRAINT chk_downtime  CHECK (downtime_hours >= 0),
  ADD CONSTRAINT chk_failures  CHECK (failure_event_count >= 0),
  ADD CONSTRAINT chk_class     CHECK (maintenance_class IN (1, 2, 3));

CREATE INDEX idx_dev_type  ON devices_clean(device_type);
CREATE INDEX idx_dev_manu  ON devices_clean(manufacturer);
CREATE INDEX idx_dev_issue ON devices_clean(issue_type);

-- ---------------------------------------------------------------
-- 3.11 Results: the "after" picture
-- ---------------------------------------------------------------
SELECT * FROM cleaning_log ORDER BY step_no;

SELECT
    (SELECT COUNT(*) FROM raw_devices)                                  AS raw_rows,
    (SELECT COUNT(*) FROM devices_clean)                                AS clean_rows,
    (SELECT COUNT(*) FROM devices_clean WHERE dq_issue IS NOT NULL)     AS rows_with_dq_issue,
    (SELECT COUNT(*) FROM devices_clean WHERE is_cost_outlier)          AS cost_outliers,
    (SELECT COUNT(*) FROM devices_clean WHERE is_downtime_outlier)      AS downtime_outliers;

-- Before vs after for the report text
SELECT r.maintenance_report AS before_cleaning,
       c.maintenance_report AS after_cleaning,
       c.report_category, c.issue_type, c.action_taken
FROM raw_devices r
JOIN devices_clean c ON c.device_id = r.device_id
WHERE r.maintenance_report ~* '\m(\w+)\s+\1\M'
LIMIT 5;
