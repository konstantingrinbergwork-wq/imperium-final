-- Миграция: таблица архива событий
CREATE TABLE IF NOT EXISTS public.events_archive (LIKE public.events INCLUDING ALL);
-- Индексы, как в основной таблице:
CREATE INDEX IF NOT EXISTS idx_events_archive_correlation_id ON public.events_archive (correlation_id);
CREATE INDEX IF NOT EXISTS idx_events_archive_status ON public.events_archive (status);
CREATE INDEX IF NOT EXISTS idx_events_archive_created_at ON public.events_archive (created_at);
CREATE INDEX IF NOT EXISTS idx_events_archive_embedding ON public.events_archive (embedding);
