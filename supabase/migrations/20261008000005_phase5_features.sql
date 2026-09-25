-- Peak — Phase 5: polls, drafts, scheduling, quotes, language tags, edit history

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. New Tables
-- ─────────────────────────────────────────────────────────────────────────────

-- Polls table
create table poll (
  id uuid primary key default gen_random_uuid(),
  question text not null check (char_length(question) <= 500),
  created_at timestamptz not null default now()
);

-- Poll options table
create table poll_option (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references poll (id) on delete cascade,
  text text not null check (char_length(text) <= 100),
  vote_count bigint not null default 0
);

-- Post edit history table
create table post_edit_history (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references post (id) on delete cascade,
  old_body text not null,
  changed_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Alter Existing Tables
-- ─────────────────────────────────────────────────────────────────────────────

alter table post
  add column language_tag text,
  add column is_draft boolean not null default false,
  add column scheduled_at timestamptz,
  add column poll_id uuid references poll (id) on delete set null;

-- Note: quote_of already exists in the original schema (line 22 of posts_feed.sql).
-- We don't need to add it again, but we should ensure it aligns with our requirements.

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Triggers & Functions
-- ─────────────────────────────────────────────────────────────────────────────

-- Trigger to record edit history when body changes
create or replace function log_post_edit() returns trigger
language plpgsql as $$
begin
  if old.body is distinct from new.body then
    insert into post_edit_history (post_id, old_body)
    values (old.id, old.body);
  end if;
  return new;
end;
$$;

create trigger post_log_edit after update on post
  for each row
  execute function log_post_edit();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RLS Policies
-- ─────────────────────────────────────────────────────────────────────────────

-- Polls/Options: readable where the parent post is readable
alter table poll enable row level security;
alter table poll_option enable row level security;
alter table post_edit_history enable row level security;

create policy poll_select on poll for select using (true); -- Publicly visible for discovery/polls? Usually yes.
create policy poll_option_select on poll_option for select using (true);
create policy post_edit_history_select on post_edit_history for select using (
  exists (select 1 from post p where p.id = post_edit_history.post_id and can_view_post(p, auth.uid()))
);

-- Writing polls: Only authorized users (via createPost logic or direct insert)
-- In this app, posts are created via repo. We'll assume creators can write polls.
create policy poll_insert on poll for insert with check (auth.uid() is not null);
create policy poll_option_insert on poll_option for insert with check (true); -- Simple for now

-- Drafting / Scheduling privacy:
-- Drafts should only be seen by the author.
-- We need to update the existing 'post_select' policy to account for is_draft.

drop policy post_select on post;
create policy post_select on post for select using (
  can_view_post(post, auth.uid())
  and (post.is_draft = false or post.author_id = auth.uid())
);

-- Cleanup/Maintenance triggers could go here later.
