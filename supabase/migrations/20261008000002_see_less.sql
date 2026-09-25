-- One tap on "why am I seeing this?" remembers that reason for this person.
-- Feeds skip matching reasons. rank_score is not involved.

create table feed_see_less (
  user_id uuid not null references profile (id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 240),
  created_at timestamptz not null default now(),
  primary key (user_id, reason)
);

alter table feed_see_less enable row level security;

create policy feed_see_less_own on feed_see_less
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());
