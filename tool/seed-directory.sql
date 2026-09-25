-- Peak — directory seed: house account, mirror/news accounts, and starter
-- communities for space, gaming, and science.
--
-- NOT a migration: this inserts real content and touches auth.users, so it must
-- never run in CI. Apply it to the hosted project by hand (Supabase MCP
-- execute_sql, or `psql` with the service role). Idempotent — safe to re-run;
-- it upserts accounts/communities and only seeds a community's kickoff post
-- when that community has none.
--
-- The mirror/news accounts are filled automatically by the `ingest-content`
-- Edge Function (see supabase/functions/ingest-content).
\set ON_ERROR_STOP on

do $$
declare
  r            record;
  v_id         uuid;
  v_persona    uuid;
  v_comm       uuid;
  v_me         uuid;   -- the human operator's account, if present
  v_now        timestamptz := now();

  -- handle, display_name, bio
  bots text[][] := array[
    array['peak',    'Peak',
          'The house account. Announcements, and a hand curating the starter communities. Not a person.'],
    array['webb',    'James Webb Space Telescope',
          'Fresh imagery from JWST, mirrored from ESA/Webb. Community-run, not an official account.'],
    array['hubble',  'Hubble Space Telescope',
          'New pictures from Hubble, mirrored from ESA/Hubble. Community-run, not an official account.'],
    array['roman',   'Nancy Grace Roman Space Telescope',
          'Nancy Grace Roman Space Telescope — mission updates and imagery as it arrives (launch expected 2027). Community-run mirror.'],
    array['launches','Rocket Launches',
          'Upcoming orbital launches worldwide, from the free Launch Library. Community-run, not affiliated with any provider.'],
    array['playstation','PlayStation News',
          'Headlines from PlayStation.Blog, mirrored with a link back. Community-run, not affiliated with Sony.'],
    array['xbox',    'Xbox News',
          'Headlines from Xbox Wire, mirrored with a link back. Community-run, not affiliated with Microsoft.'],
    array['nintendo','Nintendo News',
          'Nintendo headlines via Nintendo Life, mirrored with a link back. Community-run, not affiliated with Nintendo.'],
    array['pcgaming','PC Gaming News',
          'PC gaming headlines from PC Gamer and Rock Paper Shotgun, mirrored with a link back. Community-run.'],
    array['pchardware','PC Hardware News',
          'CPU / GPU / component news from Tom''s Hardware and TechPowerUp, mirrored with a link back. Community-run.'],
    array['scinews', 'Science News',
          'Research headlines from Phys.org and ScienceDaily, mirrored with a link back. Community-run.'],
    array['spacevideos', 'Space Videos',
          'Space and astronomy video picks from melodysheep, Everyday Astronaut, SpaceX, and Cool Worlds, mirrored with a link back. Community-run, not affiliated with any channel.']
  ];

  -- slug, name, description, topics(csv)
  comms text[][] := array[
    array['gaming', 'Gaming',
          'Everything games — what you''re playing, news, mods, hardware, and screenshots.',
          'gaming,games,indie'],
    array['playstation', 'PlayStation',
          'PlayStation news and discussion — PS5, PS Plus, first-party studios, and the back catalogue. Fed by @playstation.',
          'gaming,playstation,ps5,sony'],
    array['xbox', 'Xbox',
          'Xbox news and discussion — consoles, Game Pass, Xbox studios, and PC. Fed by @xbox.',
          'gaming,xbox,microsoft,game-pass'],
    array['nintendo', 'Nintendo',
          'Nintendo news and discussion — Switch, first-party games, Directs, and the eShop. Fed by @nintendo.',
          'gaming,nintendo,switch'],
    array['pc-gaming', 'PC Gaming',
          'PC gaming — new releases, storefront deals, mods, and the culture. Fed by @pcgaming.',
          'gaming,pc-gaming,pc,steam'],
    array['pc-hardware', 'PC Hardware',
          'Building and upgrading PCs — CPU / GPU / memory releases, reviews, and troubleshooting. Fed by @pchardware.',
          'hardware,pc,cpu,gpu,components'],
    array['rockets', 'Rocket Launches',
          'Spaceflight and the launch schedule — SpaceX, ULA, Rocket Lab, ESA, ISRO, CNSA and the rest. Countdowns, scrubs, and post-flight.',
          'rockets,spaceflight,spacex,launches,orbital'],
    array['science', 'Science',
          'Science across the board — physics, biology, earth, space, and the papers behind the headlines. Cite your source.',
          'science,research,physics,biology,earth'],
    array['science-news', 'Science News',
          'A running feed of new research, plainly summarised with a link to the source. Fed by @scinews.',
          'science,research,news'],
    array['astrophotos', 'Telescope Images',
          'The newest images from Webb, Hubble, and (soon) Roman, plus your own astrophotography. Auto-fed by @webb, @hubble, and @roman.',
          'astrophotography,jwst,hubble,astronomy,images'],
    array['space', 'Space',
          'The home space for astronomy, missions, and anything off the planet. Imagery from @webb, @hubble, and @roman lands here, plus video picks from @spacevideos.',
          'space,astronomy,nasa,missions'],
    array['movies', 'Movies',
          'Films, what you just watched, and what is worth the runtime. No spoilers in the first line.',
          'movies,film,cinema'],
    array['music', 'Music',
          'What you are listening to, shows, and new releases. Share a song, not a streaming chart.',
          'music,albums,shows'],
    array['books', 'Books',
          'What you are reading and what stuck with you. Cite the book, not a plot dump.',
          'books,reading,literature'],
    array['photography', 'Photography',
          'Photos you took. Say what the camera saw; the picture can do the rest.',
          'photography,photos,cameras'],
    array['cooking', 'Cooking',
          'Recipes, technique, and what you actually ate. Write it so someone else can cook it.',
          'cooking,food,recipes'],
    array['outdoors', 'Outdoors',
          'Trails, weather, and time outside. Tell people where, and what the day was like.',
          'outdoors,hiking,nature'],
    array['cars', 'Cars',
          'Cars, bikes, and the work of keeping them running. Builds and road trips welcome.',
          'cars,automotive,bikes'],
    array['programming', 'Programming',
          'Code, tools, and things you shipped. Show the problem and what you tried.',
          'programming,code,software'],
    array['linux', 'Linux',
          'Linux on the desktop and the server. Configs, bugs, and the fix that worked.',
          'linux,foss,desktop'],
    array['art', 'Art',
          'Drawing, painting, and work in progress. Credit yourself; say what it is.',
          'art,drawing,painting'],
    array['history', 'History',
          'History with a source. The story, then where it comes from.',
          'history,archives'],
    array['aviation', 'Aviation',
          'Aircraft, airports, and flight. Spotting, training, and how the machine works.',
          'aviation,aircraft,flight'],
    array['anime', 'Anime',
          'Series and films. Say what you are watching; keep the first line spoiler-free.',
          'anime,animation'],
    array['fitness', 'Fitness',
          'Training you actually do. No before-and-after bait, no supplement pitches.',
          'fitness,training,health'],
    array['weather', 'Weather',
          'What the sky is doing where you are, and the systems behind it.',
          'weather,storms,climate']
  ];

  -- bot handle -> community slug it posts into (beyond the space defaults)
  wiring text[][] := array[
    array['webb','astrophotos'], array['hubble','astrophotos'], array['roman','astrophotos'],
    array['webb','space'], array['hubble','space'], array['roman','space'], array['nasa','space'],
    array['launches','rockets'], array['launches','space'],
    array['spacevideos','space'],
    array['playstation','playstation'], array['playstation','gaming'],
    array['xbox','xbox'], array['xbox','gaming'],
    array['nintendo','nintendo'], array['nintendo','gaming'],
    array['pcgaming','pc-gaming'], array['pcgaming','gaming'],
    array['pchardware','pc-hardware'],
    array['scinews','science-news'], array['scinews','science']
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
    ('pc-hardware', 'builds',      'Builds',      'Show your rig / parts list',     1, 'members'),
    ('pc-hardware', 'help',        'Help',        'Troubleshooting and advice',     2, 'members'),
    ('science',     'papers',      'Papers',      'New results, with the source',   1, 'members'),
    ('astrophotos', 'yours',       'Your shots',  'Astrophotography you took',      1, 'members')
  ) as x(cslug, slug, name, descr, pos, pol) on x.cslug = c.slug
  on conflict (community_id, slug) do nothing;

  ---------------------------------------------------------------------------
  -- 3. mirror/news accounts join the communities they feed
  ---------------------------------------------------------------------------
  for i in 1 .. array_length(wiring, 1) loop
    insert into community_member (community_id, member_id, role, state)
    select c.id, u.id, 'member', 'active'
    from community c, auth.users u
    where c.slug = wiring[i][2]
      and u.email = wiring[i][1] || '@peak.social'
    on conflict (community_id, member_id) do nothing;
  end loop;

  ---------------------------------------------------------------------------
  -- 4. wire the human operator in (whoever holds the oldest real @handle),
  --    so their home feed + communities + Discover are populated from day one.
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
    where u.email like '%@peak.social' and u.id <> v_me
      and u.email <> 'peak@peak.social'
    on conflict do nothing;

    insert into follow (follower_id, followee_id)
    select v_me, u.id from auth.users u where u.email = 'peak@peak.social'
    on conflict do nothing;

    insert into community_member (community_id, member_id, role, state)
    select c.id, v_me, 'member', 'active' from community c
    on conflict (community_id, member_id) do nothing;

    insert into profile_interest (profile_id, topic)
    select v_me, t from unnest(array[
      'space','astronomy','science','gaming','rockets',
      'playstation','xbox','nintendo','pc gaming','hardware'
    ]) as t
    on conflict do nothing;
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
    where not exists (select 1 from post p where p.community_id = c.id)
      and c.slug in ('gaming','rockets','science','astrophotos','playstation',
                     'xbox','nintendo','pc-gaming','pc-hardware','science-news',
                     'space','movies','music','books','photography','cooking',
                     'outdoors','cars','programming','linux','art','history',
                     'aviation','anime','fitness','weather')
  loop
    insert into post (author_id, persona_id, community_id, channel_id, body, visibility, created_at)
    values (v_id, v_persona, r.comm, r.chan,
      case r.slug
        when 'gaming' then
E'Welcome to Gaming on Peak. No engagement bait, no algorithm deciding what you see — just people talking about games.\n\nPlatform-specific news lives in c/playstation, c/xbox, c/nintendo, c/pc-gaming and c/pc-hardware. Start here: what are you playing this week?'
        when 'playstation' then
E'PlayStation news and talk. @playstation mirrors headlines from PlayStation.Blog into this community; bring your own finds and hot takes.'
        when 'xbox' then
E'Xbox news and talk. @xbox mirrors headlines from Xbox Wire into this community; Game Pass adds, hardware, studios — all fair game.'
        when 'nintendo' then
E'Nintendo news and talk. @nintendo mirrors headlines from Nintendo Life into this community. Directs, first-party games, and the perennial "new hardware when?"'
        when 'pc-gaming' then
E'PC gaming — releases, deals, mods, and the culture. @pcgaming mirrors PC Gamer and Rock Paper Shotgun here.'
        when 'pc-hardware' then
E'Building and upgrading PCs. @pchardware mirrors CPU/GPU/component news from Tom''s Hardware and TechPowerUp. Post your build in #builds, ask in #help.'
        when 'rockets' then
E'Welcome to Rocket Launches. The #schedule channel auto-fills with upcoming orbital launches worldwide (courtesy @launches); bring countdowns, scrubs, and post-flight analysis to #general and #post-flight.'
        when 'science' then
E'Welcome to Science. Physics, biology, earth, space — the results and the papers behind them. A running headline feed lives in c/science-news (via @scinews). One rule that matters: link the source.'
        when 'science-news' then
E'A running feed of new research from @scinews (Phys.org, ScienceDaily), each with a link to the source. Discuss here; take deeper threads to c/science.'
        when 'astrophotos' then
E'Welcome to Telescope Images. @webb, @hubble, and @roman post their newest imagery straight into this community as it''s published. Post your own astrophotography in #yours.'
        when 'space' then
E'Welcome to Space. Missions, astronomy, and anything off the planet. Telescope pictures also live in c/astrophotos, and the launch schedule is in c/rockets.'
        when 'movies' then
E'Welcome to Movies. What did you just watch, and was it worth the runtime? Keep spoilers out of the first line.'
        when 'music' then
E'Welcome to Music. What are you listening to? A song, a show, a record you keep coming back to.'
        when 'books' then
E'Welcome to Books. What are you reading, and what stayed with you after you closed it?'
        when 'photography' then
E'Welcome to Photography. Post a photo you took and say what the camera saw.'
        when 'cooking' then
E'Welcome to Cooking. A recipe, a technique, or what you actually made tonight. Write it so someone else can cook it.'
        when 'outdoors' then
E'Welcome to Outdoors. Trails, weather, and time outside. Say where you were.'
        when 'cars' then
E'Welcome to Cars. The machine, the work, and the road. Builds and repair notes both belong here.'
        when 'programming' then
E'Welcome to Programming. Something you shipped, a bug you chased, or a tool that earned a place in your setup.'
        when 'linux' then
E'Welcome to Linux. Desktop or server, the config and the fix. Say which distro you are on.'
        when 'art' then
E'Welcome to Art. Work in progress is welcome. Say what it is, and that you made it.'
        when 'history' then
E'Welcome to History. Tell the story, then point at the source.'
        when 'aviation' then
E'Welcome to Aviation. Aircraft, airports, and how the machine flies.'
        when 'anime' then
E'Welcome to Anime. What are you watching? Keep the first line free of spoilers.'
        when 'fitness' then
E'Welcome to Fitness. Training you actually do. No transformation bait.'
        when 'weather' then
E'Welcome to Weather. What the sky is doing where you are, and the system behind it.'
      end,
      'public', v_now - (r.slug = 'astrophotos')::int * interval '1 minute');
  end loop;

  -- a house welcome on the main feed, once
  if not exists (select 1 from post p
                 where p.author_id = v_id and p.community_id is null
                   and p.body like 'Peak is open.%') then
    insert into post (author_id, persona_id, body, visibility, created_at)
    values (v_id, v_persona,
E'Peak is open. No ads, no tracking, no algorithm you can''t turn off — you own your feed, your data, and your graph.\n\nFollow @webb, @hubble, and @roman for telescope imagery, @launches for the orbital schedule, @spacevideos for space video picks, and @playstation / @xbox / @nintendo / @pcgaming / @pchardware / @scinews for news. Communities: c/space, c/rockets, c/gaming, c/playstation, c/xbox, c/nintendo, c/pc-gaming, c/pc-hardware, c/science, c/science-news, c/astrophotos.',
      'public', v_now - interval '2 hours');
  end if;
end $$;

-- sanity
select 'accounts' as what, string_agg(p.handle, ', ' order by p.handle) as rows
from profile p join auth.users u on u.id = p.id where u.email like '%@peak.social'
union all
select 'communities', string_agg(slug, ', ' order by slug) from community
union all
select 'posts total', count(*)::text from post;
