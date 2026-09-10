-- Peak — directory seed: house account, telescope + launch mirror accounts,
-- and starter communities (gaming / rockets / science / telescope images)
-- alongside the existing Space & Astronomy community.
--
-- NOT a migration: this inserts real content and touches auth.users, so it must
-- never run in CI. Apply it to the hosted project by hand (Supabase MCP
-- execute_sql, or `psql` with the service role). Idempotent — safe to re-run;
-- it upserts accounts/communities and only seeds a community's kickoff post
-- when that community has none.
--
-- The @webb / @hubble / @roman / @launches accounts are filled automatically by
-- the `ingest-content` Edge Function (see supabase/functions/ingest-content).
\set ON_ERROR_STOP on

do $$
declare
  r            record;
  v_id         uuid;
  v_persona    uuid;
  v_comm       uuid;
  v_me         uuid;   -- the human operator's account, if present
  v_now        timestamptz := now();

  -- handle → (display_name, bio)
  bots text[][] := array[
    array['peak',    'Peak',
          'The house account. Announcements, and a hand curating the starter communities. Not a person.'],
    array['webb',    'James Webb Space Telescope',
          'Fresh imagery from JWST, mirrored from NASA''s public image library. Community-run, not an official account.'],
    array['hubble',  'Hubble Space Telescope',
          'New pictures from Hubble, mirrored from NASA''s public image library. Community-run, not an official account.'],
    array['roman',   'Nancy Grace Roman Space Telescope',
          'Nancy Grace Roman Space Telescope — mission updates and imagery as it arrives (launch expected 2027). Community-run mirror.'],
    array['launches','Rocket Launches',
          'Upcoming orbital launches worldwide, from the free Launch Library. Community-run, not affiliated with any provider.']
  ];

  -- slug, name, description, topics(csv)
  comms text[][] := array[
    array['gaming', 'Gaming',
          'Everything games — what you''re playing, news, mods, hardware, and screenshots.',
          'gaming,games,pc-gaming,consoles,indie'],
    array['rockets', 'Rocket Launches',
          'Spaceflight and the launch schedule — SpaceX, ULA, Rocket Lab, ESA, ISRO, CNSA and the rest. Countdowns, scrubs, and post-flight.',
          'rockets,spaceflight,spacex,launches,orbital'],
    array['science', 'Science',
          'Science across the board — physics, biology, earth, space, and the papers behind the headlines. Cite your source.',
          'science,research,physics,biology,earth'],
    array['astrophotos', 'Telescope Images',
          'The newest images from Webb, Hubble, and (soon) Roman, plus your own astrophotography. Auto-fed by @webb, @hubble, and @roman.',
          'astrophotography,jwst,hubble,astronomy,images']
  ];
begin
  ---------------------------------------------------------------------------
  -- 1. accounts (auth user + profile + default persona)
  ---------------------------------------------------------------------------
  for i in 1 .. array_length(bots, 1) loop
    select id into v_id from auth.users where email = bots[i][1] || '@peak.social';
    if v_id is null then
      v_id := gen_random_uuid();
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change
      ) values (
        '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
        bots[i][1] || '@peak.social',
        extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),
        v_now, '{"provider":"email","providers":["email"]}', '{}',
        v_now, v_now, '', '', '', ''
      );
    end if;

    insert into profile (id, handle, display_name, bio, domain, account_kind, verification, is_discoverable)
    values (v_id, bots[i][1], bots[i][2], bots[i][3], 'peak.social', 'adult', 'id_verified', true)
    on conflict (id) do update
      set display_name = excluded.display_name,
          bio         = excluded.bio,
          verification = excluded.verification,
          is_discoverable = true;

    if not exists (select 1 from persona where account_id = v_id) then
      insert into persona (id, account_id, label, is_default)
      values (gen_random_uuid(), v_id, 'main', true);
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- 2. communities (+ a #general channel each)
  ---------------------------------------------------------------------------
  select id into v_id from auth.users where email = 'peak@peak.social';

  for i in 1 .. array_length(comms, 1) loop
    insert into community (slug, name, description, topics, join_policy, is_listed, created_by)
    values (comms[i][1], comms[i][2], comms[i][3],
            string_to_array(comms[i][4], ','), 'open', true, v_id)
    on conflict (slug) do update
      set name = excluded.name, description = excluded.description, topics = excluded.topics;

    select id into v_comm from community where slug = comms[i][1];

    insert into community_channel (community_id, slug, name, position)
    values (v_comm, 'general', 'General', 0)
    on conflict (community_id, slug) do nothing;

    insert into community_member (community_id, member_id, role, state)
    values (v_comm, v_id, 'admin', 'active')
    on conflict (community_id, member_id) do update set role = 'admin', state = 'active';
  end loop;

  -- extra channels where they help
  insert into community_channel (community_id, slug, name, description, position, post_policy)
  select c.id, x.slug, x.name, x.descr, x.pos, x.pol::channel_post_policy
  from community c
  join (values
    ('rockets',     'schedule',    'Schedule',    'Upcoming launches, auto-posted', 1, 'members'),
    ('rockets',     'post-flight', 'Post-flight', 'How did it go?',                 2, 'members'),
    ('gaming',      'screenshots', 'Screenshots', 'Show us your best frame',        1, 'members'),
    ('gaming',      'deals',       'Deals',       'Sales and freebies',             2, 'members'),
    ('science',     'papers',      'Papers',      'New results, with the source',   1, 'members'),
    ('astrophotos', 'yours',       'Your shots',  'Astrophotography you took',      1, 'members')
  ) as x(cslug, slug, name, descr, pos, pol) on x.cslug = c.slug
  on conflict (community_id, slug) do nothing;

  ---------------------------------------------------------------------------
  -- 3. mirror accounts join the space-y communities
  ---------------------------------------------------------------------------
  insert into community_member (community_id, member_id, role, state)
  select c.id, u.id, 'member', 'active'
  from community c
  cross join lateral (
    select id, email from auth.users
    where email in ('webb@peak.social','hubble@peak.social','roman@peak.social',
                    'launches@peak.social','nasa@peak.social')
  ) u
  where (c.slug in ('space','astrophotos'))
     or (c.slug = 'rockets' and u.email = 'launches@peak.social')
  on conflict (community_id, member_id) do nothing;

  ---------------------------------------------------------------------------
  -- 4. wire the human operator in (whoever holds the oldest real @handle),
  --    so their home feed + communities are populated from day one.
  ---------------------------------------------------------------------------
  select p.id into v_me
  from profile p
  join auth.users au on au.id = p.id
  where au.email not like '%@peak.social'
  order by p.created_at
  limit 1;

  if v_me is not null then
    insert into follow (follower_id, followee_id)
    select v_me, u.id from auth.users u
    where u.email in ('nasa@peak.social','peak@peak.social','webb@peak.social',
                      'hubble@peak.social','roman@peak.social','launches@peak.social')
      and u.id <> v_me
    on conflict do nothing;

    insert into community_member (community_id, member_id, role, state)
    select c.id, v_me, 'member', 'active'
    from community c
    where c.slug in ('space','gaming','rockets','science','astrophotos')
    on conflict (community_id, member_id) do nothing;
  end if;

  ---------------------------------------------------------------------------
  -- 5. kickoff posts (only when a community has none yet)
  ---------------------------------------------------------------------------
  select u.id, pe.id into v_id, v_persona
  from auth.users u join persona pe on pe.account_id = u.id and pe.is_default
  where u.email = 'peak@peak.social';

  for r in
    select c.id as comm, ch.id as chan, c.slug
    from community c
    join community_channel ch on ch.community_id = c.id and ch.slug = 'general'
    where c.slug in ('gaming','rockets','science','astrophotos')
      and not exists (select 1 from post p where p.community_id = c.id)
  loop
    insert into post (author_id, persona_id, community_id, channel_id, body, visibility, created_at)
    values (v_id, v_persona, r.comm, r.chan,
      case r.slug
        when 'gaming' then
E'Welcome to Gaming on Peak. No engagement bait, no algorithm deciding what you see — just people talking about games.\n\nStart here: what are you playing this week, and is it worth it?'
        when 'rockets' then
E'Welcome to Rocket Launches. The #schedule channel auto-fills with upcoming orbital launches worldwide (courtesy @launches); bring countdowns, scrubs, and post-flight analysis to #general and #post-flight.'
        when 'science' then
E'Welcome to Science. Physics, biology, earth, space — the results and the papers behind them. One rule that matters: link the source, not the press-release-of-a-press-release.'
        when 'astrophotos' then
E'Welcome to Telescope Images. @webb, @hubble, and @roman post their newest imagery straight into this community as it''s published. Post your own astrophotography in #yours.'
      end,
      'public', v_now - (r.slug = 'astrophotos')::int * interval '1 minute');
  end loop;

  -- a house welcome on the main feed, once
  if not exists (select 1 from post p
                 where p.author_id = v_id and p.community_id is null
                   and p.body like 'Peak is open.%') then
    insert into post (author_id, persona_id, body, visibility, created_at)
    values (v_id, v_persona,
E'Peak is open. No ads, no tracking, no algorithm you can''t turn off — you own your feed, your data, and your graph.\n\nFollow @webb, @hubble, and @roman for fresh telescope imagery, @launches for the orbital schedule, and @nasa for spaceflight news. Communities: c/space, c/rockets, c/science, c/gaming, c/astrophotos.',
      'public', v_now - interval '2 hours');
  end if;
end $$;

-- sanity
select 'accounts' as what, string_agg(p.handle, ', ' order by p.handle) as rows
from profile p join auth.users u on u.id = p.id where u.email like '%@peak.social'
union all
select 'communities', string_agg(slug, ', ' order by slug) from community
union all
select 'posts by @peak', count(*)::text from post p
  join profile pf on pf.id = p.author_id where pf.handle = 'peak';
