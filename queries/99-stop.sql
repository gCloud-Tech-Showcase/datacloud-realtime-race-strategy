-- 99 Stop: cancel the continuous queries
-- Cancels every running continuous query that publishes race moments. The
-- reservation bills only while a continuous query runs, so run this when the
-- replay is over. The pit wall's Stop button does the same.
FOR job IN (
  SELECT job_id
  FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
  WHERE state = 'RUNNING'
    AND statement_type = 'EXPORT_DATA'
    AND query LIKE '%topics/race-moments%'
)
DO
  CALL BQ.JOBS.CANCEL(job.job_id);
END FOR;
