-- Backfill: any profile with zero circles (e.g. bootstrapped before this
-- migration existed, or bootstrapped through some path that didn't call
-- bootstrap_account()) can't post at all — the composer's "Who can see
-- this?" picker has nothing to render and "Pick at least one circle to post
-- to" blocks every post. Give every such profile the same five system
-- circles bootstrap_account() creates for new accounts.
insert into circle (owner_id, name, slug, is_system, is_public, sort_order)
select p.id, v.name, v.slug, true, v.is_public, v.sort_order
from profile p
cross join (
  values
    ('Public',        'public',       true,  0),
    ('Friends',       'friends',      false, 1),
    ('Close Friends', 'close_friends',false, 2),
    ('Family',        'family',       false, 3),
    ('Work',          'work',         false, 4)
) as v(name, slug, is_public, sort_order)
where not exists (select 1 from circle c where c.owner_id = p.id);
