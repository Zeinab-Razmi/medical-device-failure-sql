
/* =====================================================================
   STEP 4 - ANALYSIS: 16 business questions about medical device failures
   ===================================================================== */


/* ============== PART A - THE BIG PICTURE ============== */

-- Q1 How big is the fleet, and how big is the failure problem?
SELECT
    COUNT(*)                                             AS total_devices,
    SUM(failure_event_count)                             AS total_failures,
    ROUND(AVG(failure_event_count), 2)                   AS avg_failures_per_device,
    COUNT(*) FILTER (WHERE failure_event_count = 0)      AS devices_never_failed,
    ROUND(SUM(maintenance_cost), 0)                      AS total_maintenance_cost,
    ROUND(SUM(downtime_hours), 0)                        AS total_downtime_hours
FROM devices_clean;

-- Q2 What does the fleet consist of? (devices per type and country)
SELECT device_type, country, COUNT(*) AS devices
FROM devices_clean
GROUP BY device_type, country
ORDER BY device_type, devices DESC;


/* ============== PART B - RELIABILITY ============== */

-- Q3 Which device types fail the most?
SELECT device_type,
       COUNT(*)                                          AS devices,
       SUM(failure_event_count)                          AS total_failures,
       ROUND(AVG(failure_event_count), 2)                AS avg_failures_per_device,
       ROUND(100.0 * COUNT(*) FILTER (WHERE failure_event_count >= 3) / COUNT(*), 1)
                                                         AS pct_devices_3plus_failures
FROM devices_clean
GROUP BY device_type
ORDER BY avg_failures_per_device DESC;

-- Q4 Which manufacturers are the most / least reliable?
SELECT manufacturer,
       COUNT(*)                                AS devices,
       ROUND(AVG(failure_event_count), 2)      AS avg_failures,
       ROUND(AVG(downtime_hours), 1)           AS avg_downtime_h,
       RANK() OVER (ORDER BY AVG(failure_event_count)) AS reliability_rank  -- 1 = best
FROM devices_clean
GROUP BY manufacturer
ORDER BY reliability_rank;

-- Q5 For EACH device type, which manufacturer is best and worst?
WITH stats AS (
    SELECT device_type, manufacturer,
           COUNT(*) AS devices,
           ROUND(AVG(failure_event_count), 2) AS avg_failures
    FROM devices_clean
    GROUP BY device_type, manufacturer
), ranked AS (
    SELECT *,
           RANK() OVER (PARTITION BY device_type ORDER BY avg_failures ASC)  AS best_rank,
           RANK() OVER (PARTITION BY device_type ORDER BY avg_failures DESC) AS worst_rank
    FROM stats
)
SELECT device_type, manufacturer, devices, avg_failures,
       CASE WHEN best_rank = 1 THEN 'BEST' ELSE 'WORST' END AS verdict
FROM ranked
WHERE best_rank = 1 OR worst_rank = 1
ORDER BY device_type, verdict;

-- Q6 Which technical issues are most commonly reported?
SELECT issue_type,
       COUNT(*)                                            AS reports,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_of_reports
FROM devices_clean
GROUP BY issue_type
ORDER BY reports DESC;

-- Q7 Is each issue concentrated in certain device types? 
SELECT issue_type,
       COUNT(*) FILTER (WHERE device_type = 'CT Scanner')    AS ct,
       COUNT(*) FILTER (WHERE device_type = 'MRI Scanner')   AS mri,
       COUNT(*) FILTER (WHERE device_type = 'PET Scanner')   AS pet,
       COUNT(*) FILTER (WHERE device_type = 'X-Ray Machine') AS xray,
       COUNT(*) FILTER (WHERE device_type = 'Defibrillator') AS defib,
       COUNT(*) FILTER (WHERE device_type = 'Infusion Pump') AS infusion
FROM devices_clean
GROUP BY issue_type
ORDER BY issue_type;


/* ============== PART C - DRIVERS ============== */

-- Q8 Do older devices fail more?
SELECT CASE
         WHEN age_years <= 3 THEN '1) 1-3 years'
         WHEN age_years <= 6 THEN '2) 4-6 years'
         WHEN age_years <= 9 THEN '3) 7-9 years'
         ELSE                     '4) 10-12 years'
       END                                   AS age_group,
       COUNT(*)                              AS devices,
       ROUND(AVG(failure_event_count), 2)    AS avg_failures,
       ROUND(AVG(maintenance_cost), 0)       AS avg_cost,
       ROUND(AVG(downtime_hours), 1)         AS avg_downtime_h
FROM devices_clean
GROUP BY age_group
ORDER BY age_group;

-- Q9 How do failures vary with maintenance frequency?
SELECT maintenance_frequency,
       COUNT(*)                              AS devices,
       ROUND(AVG(failure_event_count), 2)    AS avg_failures,
       ROUND(AVG(downtime_hours), 1)         AS avg_downtime_h
FROM devices_clean
GROUP BY maintenance_frequency
ORDER BY maintenance_frequency;

-- Q10 Pearson correlation:
	-- +1 = strong positive linear relationship
	--  0 = little/no linear relationship
	-- -1 = strong negative linear relationship
SELECT
    ROUND(CORR(age_years,             failure_event_count)::NUMERIC, 3) AS age_vs_failures,
    ROUND(CORR(maintenance_frequency, failure_event_count)::NUMERIC, 3) AS maint_freq_vs_failures,
    ROUND(CORR(failure_event_count,   downtime_hours)::NUMERIC, 3)      AS failures_vs_downtime,
    ROUND(CORR(downtime_hours,        maintenance_cost)::NUMERIC, 3)    AS downtime_vs_cost
FROM devices_clean;


/* ============== PART D - COST & DOWNTIME IMPACT ============== */

-- Q11 What does each severity level cost?
SELECT severity_level,
       COUNT(*)                              AS devices,
       ROUND(AVG(maintenance_cost), 0)       AS avg_cost,
       ROUND(AVG(downtime_hours), 1)         AS avg_downtime_h,
       ROUND(AVG(failure_event_count), 2)    AS avg_failures
FROM devices_clean
GROUP BY severity_level, maintenance_class
ORDER BY maintenance_class;

-- Q12 Which device types are the most expensive to keep running?
SELECT device_type,
       ROUND(SUM(maintenance_cost), 0)                               AS total_cost,
       ROUND(AVG(maintenance_cost), 0)                               AS avg_cost_per_device,
       ROUND(SUM(maintenance_cost) / NULLIF(SUM(failure_event_count), 0), 0)
                                                                     AS cost_per_failure,
       ROUND(100.0 * SUM(maintenance_cost) / SUM(SUM(maintenance_cost)) OVER (), 1)
                                                                     AS pct_of_total_cost
FROM devices_clean
GROUP BY device_type
ORDER BY total_cost DESC;

-- Q13 Which recorded actions are associated with higher average downtime/cost?
SELECT action_taken,
       COUNT(*)                            AS cases,
       ROUND(AVG(downtime_hours), 1)       AS avg_downtime_h,
       ROUND(AVG(maintenance_cost), 0)     AS avg_cost
FROM devices_clean
GROUP BY action_taken
ORDER BY avg_downtime_h DESC;

-- Q14 Pareto: which manufacturer + device type combinations make up
--         the first 80% of all maintenance cost? (running total)
WITH combo AS (
    SELECT manufacturer, device_type, SUM(maintenance_cost) AS cost
    FROM devices_clean
    GROUP BY manufacturer, device_type
), running AS (
    SELECT *,
           ROUND(100.0 * SUM(cost) OVER (ORDER BY cost DESC) / SUM(cost) OVER (), 1) AS cumulative_pct
    FROM combo
)
SELECT manufacturer, device_type, ROUND(cost, 0) AS cost, cumulative_pct
FROM running
WHERE cumulative_pct <= 80
ORDER BY cost DESC;


/* ============== PART E - ACTION LIST ============== */

-- Q15 High-risk devices:
	-- at least 2x the average failures for their device type
	-- AND above-average downtime for their device type.
WITH with_avg AS (
    SELECT *,
           AVG(failure_event_count) OVER (PARTITION BY device_type) AS type_avg_failures,
           AVG(downtime_hours)      OVER (PARTITION BY device_type) AS type_avg_downtime
    FROM devices_clean
)
SELECT device_id, device_type, manufacturer, model, country, age_years,
       failure_event_count,
       ROUND(type_avg_failures, 2) AS type_avg_failures,
       downtime_hours,
       ROUND(type_avg_downtime, 1) AS type_avg_downtime,
       maintenance_cost, issue_type
FROM with_avg
WHERE failure_event_count >= 2 * type_avg_failures
  AND downtime_hours      >      type_avg_downtime
ORDER BY failure_event_count DESC, downtime_hours DESC;

-- Q16 Purchase cohorts: How does average failure count vary across purchase-year cohorts?
WITH cohort AS (
    SELECT purchase_year,
           COUNT(*)                           AS devices,
           ROUND(AVG(failure_event_count), 2) AS avg_failures
    FROM devices_clean
    GROUP BY purchase_year
)
SELECT purchase_year, devices, avg_failures,
       avg_failures - LAG(avg_failures) OVER (ORDER BY purchase_year) AS change_vs_prev_year
FROM cohort
ORDER BY purchase_year;


/* ============== PART F - SAVED VIEWS (for Power BI / Tableau / Excel) ============== */

CREATE OR REPLACE VIEW v_device_type_kpis AS
SELECT device_type,
       COUNT(*)                              AS devices,
       SUM(failure_event_count)              AS total_failures,
       ROUND(AVG(failure_event_count), 2)    AS avg_failures,
       ROUND(SUM(maintenance_cost), 0)       AS total_cost,
       ROUND(AVG(downtime_hours), 1)         AS avg_downtime_h
FROM devices_clean
GROUP BY device_type;

CREATE OR REPLACE VIEW v_high_risk_devices AS
WITH with_avg AS (
    SELECT *,
           AVG(failure_event_count) OVER (PARTITION BY device_type) AS type_avg_failures,
           AVG(downtime_hours)      OVER (PARTITION BY device_type) AS type_avg_downtime
    FROM devices_clean
)
SELECT device_id, device_type, manufacturer, model, country, age_years,
       failure_event_count, downtime_hours, maintenance_cost, issue_type
FROM with_avg
WHERE failure_event_count >= 2 * type_avg_failures
  AND downtime_hours      >      type_avg_downtime;

SELECT * FROM v_device_type_kpis ORDER BY avg_failures DESC;
SELECT COUNT(*) AS high_risk_devices FROM v_high_risk_devices;
