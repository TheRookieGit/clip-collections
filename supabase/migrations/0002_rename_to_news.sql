-- 拾闻 (news-collections): the tables take the project's new name. Their data and RLS stay as they are.
alter table clips rename to news;
alter index clips_pkey rename to news_pkey;
alter table clip_edits rename to news_edits;
alter index clip_edits_pkey rename to news_edits_pkey;
alter index clip_edits_pending rename to news_edits_pending;
alter sequence clip_edits_id_seq rename to news_edits_id_seq;
