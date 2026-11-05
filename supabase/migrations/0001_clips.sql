-- 拾闻 (clip-collections): the cloud copy the web page reads. Every table has RLS on and no policy: only the Edge
-- Function `api`, with the service role, reads and writes them. PDFs never come here.

-- News as the Mac last reported it (the Mac is the source of truth). One row per item.
create table if not exists clips (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table clips enable row level security;

-- What the web page asks the Mac to do: add, update, delete, retry. The Mac takes them in, reports the result through
-- `clips`, and marks them done. Until then the page shows them on top of `clips`, so a new item reads 待保存.
create table if not exists clip_edits (
  id bigserial primary key,
  patch jsonb not null,
  created_at timestamptz not null default now(),
  done boolean not null default false
);
alter table clip_edits enable row level security;
create index if not exists clip_edits_pending on clip_edits(id) where not done;

-- When the Mac last checked in, and whether it said it is going to sleep or quitting.
create table if not exists mac_status (
  id int primary key default 1 check (id = 1),
  seen_at timestamptz not null,
  state text not null
);
alter table mac_status enable row level security;

-- Wrong passcodes, for the lockout (20 in 10 minutes).
create table if not exists auth_failures (
  id bigserial primary key,
  at timestamptz not null default now()
);
alter table auth_failures enable row level security;
create index if not exists auth_failures_at on auth_failures(at);

-- Screenshots (s/<clip id>/<n>.jpg), private; the page gets signed links valid for an hour.
insert into storage.buckets (id, name, public) values ('shots', 'shots', false) on conflict (id) do nothing;
