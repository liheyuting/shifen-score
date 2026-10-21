create extension if not exists pgcrypto;

create table if not exists public.score_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  name text not null check (char_length(name) between 1 and 40),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.score_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.score_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  icon text not null default '🙂',
  points bigint not null default 0,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id)
);

create table if not exists public.score_events (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.score_rooms(id) on delete cascade,
  actor_member_id uuid not null references public.score_members(id),
  recipient_member_id uuid not null references public.score_members(id),
  kind text not null check (kind in ('earn', 'adjust', 'transfer')),
  amount bigint not null check (amount <> 0),
  note text not null default '' check (char_length(note) <= 120),
  created_at timestamptz not null default now()
);

create index if not exists score_members_room_points_idx on public.score_members(room_id, points desc);
create index if not exists score_events_room_created_idx on public.score_events(room_id, created_at desc);

alter table public.score_rooms enable row level security;
alter table public.score_members enable row level security;
alter table public.score_events enable row level security;

create or replace function public.is_score_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.score_members m
    where m.room_id = p_room_id and m.user_id = (select auth.uid())
  );
$$;

drop policy if exists "Room members can read their room" on public.score_rooms;
create policy "Room members can read their room" on public.score_rooms for select to authenticated
  using (public.is_score_room_member(id));

drop policy if exists "Room members can read member list" on public.score_members;
create policy "Room members can read member list" on public.score_members for select to authenticated
  using (public.is_score_room_member(room_id));

drop policy if exists "Room members can read score history" on public.score_events;
create policy "Room members can read score history" on public.score_events for select to authenticated
  using (public.is_score_room_member(room_id));

create or replace function public.create_score_room(p_name text, p_member_name text, p_icon text default '🙂')
returns table(id uuid, room_code text, name text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.score_rooms%rowtype;
  v_code text;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if char_length(trim(p_name)) not between 1 and 40 then raise exception 'Room name must be 1 to 40 characters'; end if;
  if char_length(trim(p_member_name)) not between 1 and 24 then raise exception 'Nickname must be 1 to 24 characters'; end if;

  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.score_rooms r where r.room_code = v_code);
  end loop;

  insert into public.score_rooms as r (room_code, name, created_by)
  values (v_code, trim(p_name), auth.uid())
  returning r.* into v_room;

  insert into public.score_members (room_id, user_id, display_name, icon)
  values (v_room.id, auth.uid(), trim(p_member_name), coalesce(nullif(p_icon, ''), '🙂'));

  return query select v_room.id, v_room.room_code, v_room.name;
end;
$$;

create or replace function public.join_score_room(p_room_code text, p_member_name text, p_icon text default '🙂')
returns table(id uuid, room_code text, name text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.score_rooms%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if char_length(trim(p_member_name)) not between 1 and 24 then raise exception 'Nickname must be 1 to 24 characters'; end if;

  select r.* into v_room from public.score_rooms r where r.room_code = upper(trim(p_room_code));
  if not found then raise exception 'Room code was not found'; end if;

  insert into public.score_members (room_id, user_id, display_name, icon)
  values (v_room.id, auth.uid(), trim(p_member_name), coalesce(nullif(p_icon, ''), '🙂'))
  on conflict (room_id, user_id) do update set display_name = excluded.display_name;

  return query select v_room.id, v_room.room_code, v_room.name;
end;
$$;

create or replace function public.add_score_points(p_room_id uuid, p_recipient_member_id uuid, p_amount bigint, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.score_members%rowtype;
begin
  select * into v_actor from public.score_members m
  where m.room_id = p_room_id and m.user_id = auth.uid() for update;
  if not found then raise exception 'You are not a member of this room'; end if;
  if p_amount <= 0 then raise exception 'Points to add must be positive'; end if;
  update public.score_members set points = points + p_amount
    where id = p_recipient_member_id and room_id = p_room_id;
  if not found then raise exception 'Recipient is not a member of this room'; end if;
  insert into public.score_events (room_id, actor_member_id, recipient_member_id, kind, amount, note)
  values (p_room_id, v_actor.id, p_recipient_member_id, 'earn', p_amount, left(coalesce(p_note, ''), 120));
end;
$$;

create or replace function public.adjust_score_points(p_room_id uuid, p_recipient_member_id uuid, p_delta bigint, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.score_members%rowtype;
begin
  select * into v_actor from public.score_members m
  where m.room_id = p_room_id and m.user_id = auth.uid() for update;
  if not found then raise exception 'You are not a member of this room'; end if;
  if p_delta = 0 then raise exception 'Adjustment cannot be zero'; end if;
  update public.score_members set points = points + p_delta
    where id = p_recipient_member_id and room_id = p_room_id;
  if not found then raise exception 'Recipient is not a member of this room'; end if;
  insert into public.score_events (room_id, actor_member_id, recipient_member_id, kind, amount, note)
  values (p_room_id, v_actor.id, p_recipient_member_id, 'adjust', p_delta, left(coalesce(p_note, ''), 120));
end;
$$;

create or replace function public.transfer_score_points(p_room_id uuid, p_recipient_member_id uuid, p_amount bigint, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.score_members%rowtype;
begin
  select * into v_actor from public.score_members m
  where m.room_id = p_room_id and m.user_id = auth.uid() for update;
  if not found then raise exception 'You are not a member of this room'; end if;
  if p_amount <= 0 then raise exception 'Transfer amount must be positive'; end if;
  if v_actor.id = p_recipient_member_id then raise exception 'Cannot transfer points to yourself'; end if;
  update public.score_members set points = points - p_amount where id = v_actor.id;
  update public.score_members set points = points + p_amount
    where id = p_recipient_member_id and room_id = p_room_id;
  if not found then raise exception 'Recipient is not a member of this room'; end if;
  insert into public.score_events (room_id, actor_member_id, recipient_member_id, kind, amount, note)
  values (p_room_id, v_actor.id, p_recipient_member_id, 'transfer', p_amount, left(coalesce(p_note, ''), 120));
end;
$$;

revoke all on function public.create_score_room(text, text, text) from public;
revoke all on function public.is_score_room_member(uuid) from public;
revoke all on function public.join_score_room(text, text, text) from public;
revoke all on function public.add_score_points(uuid, uuid, bigint, text) from public;
revoke all on function public.adjust_score_points(uuid, uuid, bigint, text) from public;
revoke all on function public.transfer_score_points(uuid, uuid, bigint, text) from public;

grant execute on function public.create_score_room(text, text, text) to authenticated;
grant execute on function public.is_score_room_member(uuid) to authenticated;
grant execute on function public.join_score_room(text, text, text) to authenticated;
grant execute on function public.add_score_points(uuid, uuid, bigint, text) to authenticated;
grant execute on function public.adjust_score_points(uuid, uuid, bigint, text) to authenticated;
grant execute on function public.transfer_score_points(uuid, uuid, bigint, text) to authenticated;

grant select on public.score_rooms, public.score_members, public.score_events to authenticated;
grant usage on schema public to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'score_members'
  ) then
    alter publication supabase_realtime add table public.score_members;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'score_events'
  ) then
    alter publication supabase_realtime add table public.score_events;
  end if;
end;
$$;
