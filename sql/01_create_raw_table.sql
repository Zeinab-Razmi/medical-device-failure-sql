/* =====================================================================
   MEDICAL DEVICE FAILURE PROJECT
   STEP 1 - CREATE THE RAW (STAGING) TABLE
   Dataset : Medical Device Failure Dataset - (Anonymized), Kaggle
   File    : Medical_Device_Failure_dataset.csv  (4,149 rows, 13 columns)
   ---------------------------------------------------------------------
   Every column is imported as TEXT so that unexpected values can be loaded first and validated during the profiling/cleaning stage.
   ===================================================================== */

DROP TABLE IF EXISTS raw_devices CASCADE;

CREATE TABLE raw_devices (
    device_id              TEXT,                
    device_type            TEXT,              
    purchase_date          TEXT,             
    age                    TEXT,                       
    manufacturer           TEXT,   
    model                  TEXT,                    
    country                TEXT,   
    maintenance_cost       TEXT,   
    downtime               TEXT,                 
    maintenance_frequency  TEXT,    
    failure_event_count    TEXT,       
    maintenance_class      TEXT,         
    maintenance_report     TEXT        
);

/* ---------------------------------------------------------------------
   IMPORT THE CSV:
   --------------------------------------------------------------------- */

SELECT COUNT(*) AS total_rows
FROM raw_devices;

SELECT COUNT(DISTINCT device_id) AS unique_devices
FROM raw_devices;

SELECT *
FROM raw_devices
LIMIT 10;
