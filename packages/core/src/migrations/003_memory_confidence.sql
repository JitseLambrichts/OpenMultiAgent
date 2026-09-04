CREATE TRIGGER memory_confidence_insert
BEFORE INSERT ON memory
WHEN NEW.confidence < 0 OR NEW.confidence > 1
BEGIN
  SELECT RAISE(ABORT, 'memory confidence must be between 0 and 1');
END;

CREATE TRIGGER memory_confidence_update
BEFORE UPDATE OF confidence ON memory
WHEN NEW.confidence < 0 OR NEW.confidence > 1
BEGIN
  SELECT RAISE(ABORT, 'memory confidence must be between 0 and 1');
END;
