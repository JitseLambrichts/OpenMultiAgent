-- Repair databases on which the old v4 runner recorded success after only a
-- prefix of the multi-statement migration was executed.
UPDATE agent_run
   SET native_session_id = NULL
 WHERE rowid IN (
   SELECT rowid FROM (
     SELECT rowid,
            ROW_NUMBER() OVER (
              PARTITION BY agent, native_session_id
              ORDER BY started_at, id
            ) AS claim_number
       FROM agent_run
      WHERE native_session_id IS NOT NULL
   )
   WHERE claim_number > 1
 );

UPDATE agent_run
   SET transcript_path = NULL
 WHERE rowid IN (
   SELECT rowid FROM (
     SELECT rowid,
            ROW_NUMBER() OVER (
              PARTITION BY transcript_path
              ORDER BY started_at, id
            ) AS claim_number
       FROM agent_run
      WHERE transcript_path IS NOT NULL
   )
   WHERE claim_number > 1
 );

CREATE UNIQUE INDEX IF NOT EXISTS agent_run_native_unique
  ON agent_run (agent, native_session_id)
  WHERE native_session_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS agent_run_transcript_unique
  ON agent_run (transcript_path)
  WHERE transcript_path IS NOT NULL;
