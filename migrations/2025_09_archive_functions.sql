-- Функция перемещения событий в архив
CREATE OR REPLACE FUNCTION public.archive_events(p_older_than interval DEFAULT '7 days')
RETURNS TABLE(moved_count int) LANGUAGE plpgsql AS $$
DECLARE
  moved_ids bigint[];
BEGIN
  WITH moved AS (
    INSERT INTO public.events_archive
      SELECT * FROM public.events WHERE created_at < now() - p_older_than
      RETURNING id
  )
  SELECT array_agg(id) INTO moved_ids FROM moved;
  DELETE FROM public.events WHERE id = ANY(moved_ids);
  RETURN QUERY SELECT COALESCE(array_length(moved_ids,1),0);
END;
$$;

-- Функция очистки очереди аудита
CREATE OR REPLACE FUNCTION public.cleanup_audit(p_older_than interval DEFAULT '30 days')
RETURNS TABLE(cleaned_count int) LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
    DELETE FROM public.audit_queue
    WHERE status IN ('approved','rejected','timeout')
      AND processed_at < now() - p_older_than
    RETURNING count(*);
END;
$$;
