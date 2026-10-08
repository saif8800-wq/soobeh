-- ============================================================
-- SOOBEH KIOSK — 01_schema.sql
-- Jadual + RLS (keselamatan baris) + RPC + trigger
-- Jalankan SEKALI di: Supabase → SQL Editor → New query → Run
-- ============================================================

-- Zon waktu Malaysia (supaya current_date tepat utk peraturan tempahan)
alter database postgres set timezone to 'Asia/Kuala_Lumpur';

-- 1) Bersihkan versi lama (untuk reset penuh, jalankan 01 semula kemudian 02)
drop table if exists public.audit cascade;
drop table if exists public.notifications cascade;
drop table if exists public.payslips cascade;
drop table if exists public.swaps cascade;
drop table if exists public.sales cascade;
drop table if exists public.published cascade;
drop table if exists public.schedule cascade;
drop table if exists public.bookings cascade;
drop table if exists public.settings cascade;
drop table if exists public.profiles cascade;
drop function if exists public.admin_create_user(text,text,text,text,text,text);
drop function if exists public.admin_reset_pin(text,text);
drop function if exists public.publish_month(text,text);
drop function if exists public.respond_swap(uuid,boolean);
drop function if exists public.decide_swap(uuid,boolean);
drop function if exists public.slot_counts(text);
drop function if exists public.my_role();
drop function if exists public.is_manager();
drop function if exists public.is_admin();
drop function if exists public.is_sales_editor();
drop function if exists public.fill_audit();
drop function if exists public.booking_guard();

-- 2) JADUAL
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  name text not null,
  phone text default '—',
  role text not null check (role in ('staff','manager','admin')),
  pay_cycle text not null default 'monthly' check (pay_cycle in ('monthly','biweekly')),
  typhoid_count int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.settings (
  id int primary key default 1 check (id = 1),
  base_rate numeric not null default 8,
  high_rate numeric not null default 9,
  weekday_threshold numeric not null default 300,
  weekend_threshold numeric not null default 400,
  monthly_sales_threshold numeric not null default 3000,
  perf_bonus numeric not null default 100,
  att_bonus numeric not null default 30,
  typhoid_allowance numeric not null default 10,
  typhoid_max int not null default 5,
  max_per_shift int not null default 2,
  shift_hours numeric not null default 6,
  allow_staff_sales boolean not null default false,
  updated_at timestamptz not null default now()
);
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  shift text not null check (shift in ('morning','evening')),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.schedule (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  shift text not null check (shift in ('morning','evening')),
  staff_id uuid not null references auth.users(id) on delete cascade,
  no_show boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.published (
  month_key text primary key,
  published_by uuid references auth.users(id) on delete set null,
  published_at timestamptz not null default now()
);
create table public.swaps (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.schedule(id) on delete cascade,
  exchange_entry_id uuid references public.schedule(id) on delete set null,
  from_staff uuid not null references auth.users(id) on delete cascade,
  to_staff uuid not null references auth.users(id) on delete cascade,
  reason text default '',
  status text not null default 'pending_peer'
    check (status in ('pending_peer','pending_manager','approved','declined','rejected')),
  t_peer timestamptz, t_mgr timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.sales (
  date date not null,
  shift text not null check (shift in ('morning','evening')),
  amount numeric not null check (amount >= 0 and amount <= 99999),
  entered_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (date, shift)
);
create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references auth.users(id) on delete cascade,
  start date not null, "end" date not null,
  cycle text not null,
  payload jsonb not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (staff_id, start)
);
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  msg text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  by_username text,
  action text not null,
  detail text default ''
);

-- 3) FUNGSI PERANAN (security definer → elak rekursi RLS)
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$   select role from public.profiles where id = auth.uid();
 $$;
create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$   select coalesce((select role in ('manager','admin') from public.profiles where id = auth.uid()), false);
 $$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$   select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false);
 $$;
create or replace function public.is_sales_editor() returns boolean
language sql stable security definer set search_path = public as $$   select coalesce((
    select (p.role in ('manager','admin'))
        or (p.role = 'staff' and coalesce((select allow_staff_sales from public.settings where id = 1), false))
    from public.profiles p where p.id = auth.uid()), false);
 $$;

-- 4) RLS — dikuatkuasakan DI DATABASE (bukan di browser)
alter table public.profiles     enable row level security;
alter table public.settings     enable row level security;
alter table public.bookings     enable row level security;
alter table public.schedule     enable row level security;
alter table public.published    enable row level security;
alter table public.swaps        enable row level security;
alter table public.sales        enable row level security;
alter table public.payslips     enable row level security;
alter table public.notifications enable row level security;
alter table public.audit        enable row level security;

create policy p_profiles_sel on public.profiles for select to authenticated using (true);
create policy p_profiles_upd on public.profiles for update to authenticated using (public.is_manager()) with check (public.is_manager());

create policy p_settings_sel on public.settings for select to authenticated using (true);
create policy p_settings_upd on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Tempahan: staff hanya nampak MILIK sendiri; manager nampak semua.
-- (Kiraan rakan diberikan melalui RPC slot_counts — tanpa nama, PRD 5.2)
create policy p_bookings_sel on public.bookings for select to authenticated
  using (staff_id = auth.uid() or public.is_manager());
create policy p_bookings_ins on public.bookings for insert to authenticated
  with check (staff_id = auth.uid() or public.is_manager());
create policy p_bookings_upd on public.bookings for update to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy p_bookings_del on public.bookings for delete to authenticated
  using ((staff_id = auth.uid() and status = 'pending') or public.is_manager());

create policy p_schedule_sel on public.schedule for select to authenticated using (true);
create policy p_schedule_upd on public.schedule for update to authenticated
  using (public.is_manager()) with check (public.is_manager());

create policy p_published_sel on public.published for select to authenticated using (true);

create policy p_swaps_sel on public.swaps for select to authenticated
  using (from_staff = auth.uid() or to_staff = auth.uid() or public.is_manager());
create policy p_swaps_ins on public.swaps for insert to authenticated
  with check (from_staff = auth.uid());

create policy p_sales_sel on public.sales for select to authenticated using (true);
create policy p_sales_ins on public.sales for insert to authenticated with check (public.is_sales_editor());
create policy p_sales_upd on public.sales for update to authenticated using (public.is_sales_editor()) with check (public.is_sales_editor());

-- Slip gaji: staff HANYA miliknya; hanya manager boleh jana/ubah/padam
create policy p_payslips_sel on public.payslips for select to authenticated
  using (staff_id = auth.uid() or public.is_manager());
create policy p_payslips_ins on public.payslips for insert to authenticated with check (public.is_manager());
create policy p_payslips_del on public.payslips for delete to authenticated using (public.is_manager());

create policy p_notif_sel on public.notifications for select to authenticated using (user_id = auth.uid());
create policy p_notif_ins on public.notifications for insert to authenticated with check (true);
create policy p_notif_upd on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Audit: sesiapa boleh tulis (trigger isi username sebenar), hanya manager boleh baca,
-- TIADA policy update/delete → log tidak boleh diubah sesiapa melalui API
create policy p_audit_ins on public.audit for insert to authenticated with check (true);
create policy p_audit_sel on public.audit for select to authenticated using (public.is_manager());

-- 5) TRIGGER — audit & perlindungan peraturan tempahan
create or replace function public.fill_audit() returns trigger
language plpgsql security definer set search_path = public as $$ begin
  new.by_username := coalesce((select username from public.profiles where id = auth.uid()), 'system');
  return new;
end $$;
create trigger trg_audit_fill before insert on public.audit
for each row execute function public.fill_audit();

create or replace function public.booking_guard() returns trigger
language plpgsql set search_path = public, auth as $$ declare v_max int; v_n int;
begin
  if auth.uid() is null then return new; end if; -- seeding/maintenance oleh postgres (SQL editor)
  if tg_op = 'INSERT' and new.status = 'pending' then
    if new.staff_id <> auth.uid() and public.my_role() not in ('manager','admin') then
      raise exception 'Akses ditolak';
    end if;
    if new.date <= current_date then raise exception 'Tarikh lampau — tempahan tertutup'; end if;
    if new.date > current_date + 62 then raise exception 'Tempahan dibenarkan dalam 62 hari sahaja'; end if;
    if exists (select 1 from public.bookings
               where staff_id = new.staff_id and date = new.date and shift = new.shift
                 and status in ('pending','approved')) then
      raise exception 'Anda sudah menempah slot ini';
    end if;
    select max_per_shift into v_max from public.settings where id = 1;
    select count(*) into v_n from public.bookings
      where date = new.date and shift = new.shift and status in ('pending','approved');
    if v_n >= v_max then raise exception 'Slot penuh (had % staff/syif)', v_max; end if;
  end if;
  if tg_op = 'UPDATE' and new.status = 'approved' and old.status <> 'approved' then
    select max_per_shift into v_max from public.settings where id = 1;
    select count(*) into v_n from public.bookings
      where date = new.date and shift = new.shift and status = 'approved' and id <> new.id;
    if v_n >= v_max then raise exception 'Had maksimum % staff/syif dicapai', v_max; end if;
  end if;
  return new;
end $$;
create trigger trg_booking_guard before insert or update on public.bookings
for each row execute function public.booking_guard();

-- 6) RPC — logik sensitif di SERVER (peranan disemak di sini)

-- Cipta akaun (manager boleh cipta staff; admin boleh cipta semua peranan)
create or replace function public.admin_create_user(
  p_username text, p_name text, p_phone text, p_role text, p_pay_cycle text, p_pin text
) returns uuid
language plpgsql security definer set search_path = public, auth, extensions as $$ declare v_id uuid; v_caller text;
begin
  v_caller := public.my_role();
  if auth.uid() is not null and v_caller not in ('manager','admin') then
    raise exception 'Akses ditolak';
  end if;
  if auth.uid() is null and current_user <> 'postgres' then
    raise exception 'Akses ditolak';
  end if;
  if p_username !~ '^[a-z0-9_.-]{2,20}$' then raise exception 'Username tidak sah'; end if;
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN mesti 4-6 digit'; end if;
  if p_role not in ('staff','manager','admin') then raise exception 'Peranan tidak sah'; end if;
  if p_pay_cycle not in ('monthly','biweekly') then raise exception 'Kitaran tidak sah'; end if;
  if v_caller = 'manager' and p_role <> 'staff' then raise exception 'Manager hanya boleh menambah akaun staff'; end if;
  if exists (select 1 from public.profiles where username = p_username) then raise exception 'Username sudah wujud'; end if;
  if exists (select 1 from auth.users where email = p_username || '@soobeh.app') then raise exception 'Username sudah wujud'; end if;

  v_id := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
      raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      p_username || '@soobeh.app', extensions.crypt(p_pin || '-soobeh', extensions.gen_salt('bf')),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('name', p_name, 'username', p_username),
      now(), now(), now());
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', p_username || '@soobeh.app', 'email_verified', true),
      'email', now(), now(), now());
  insert into public.profiles (id, username, name, phone, role, pay_cycle)
  values (v_id, p_username, p_name, coalesce(nullif(p_phone, ''), '—'), p_role, p_pay_cycle);
  return v_id;
end $$;

-- Set semula PIN (PRD 5.1 — tanpa OTP/emel)
create or replace function public.admin_reset_pin(p_username text, p_pin text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$ begin
  if auth.uid() is null or public.my_role() not in ('manager','admin') then
    raise exception 'Akses ditolak';
  end if;
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN meste 4-6 digit'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_pin || '-soobeh', extensions.gen_salt('bf')),
         updated_at = now()
   where email = p_username || '@soobeh.app';
  if not found then raise exception 'Pengguna tidak dijumpai'; end if;
end $$;

-- Keluarkan jadual rasmi (PRD 5.3) — atomic di server
create or replace function public.publish_month(p_month text, p_label text) returns int
language plpgsql security definer set search_path = public, auth as $$ declare v_n int;
begin
  if auth.uid() is null or not public.is_manager() then raise exception 'Akses ditolak'; end if;
  if p_month !~ '^[0-9]{4}-[0-9]{2}$' then raise exception 'Bulan tidak sah'; end if;
  if exists (select 1 from public.published where month_key = p_month) then
    raise exception 'Jadual bulan ini sudah dikeluarkan';
  end if;
  insert into public.schedule (date, shift, staff_id)
  select b.date, b.shift, b.staff_id from public.bookings b
  where b.status = 'approved' and to_char(b.date, 'YYYY-MM') = p_month;
  get diagnostics v_n = row_count;
  update public.bookings set status = 'rejected', decided_by = auth.uid(), decided_at = now()
  where status = 'pending' and to_char(date, 'YYYY-MM') = p_month;
  insert into public.published (month_key, published_by) values (p_month, auth.uid());
  insert into public.notifications (user_id, msg)
  select p.id, '📅 Jadual rasmi ' || p_label || ' telah DIKELUARKAN. Sila semak "Jadual Saya".'
  from public.profiles p where p.role = 'staff' and p.active;
  insert into public.audit (action, detail) values ('schedule_publish', p_label || ' — ' || v_n || ' slot disahkan');
  return v_n;
end $$;

-- Rakan bersetuju/tolak pertukaran (PRD 5.4 — peringkat 1)
create or replace function public.respond_swap(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public, auth as $$ declare s record;
begin
  if auth.uid() is null then raise exception 'Akses ditolak'; end if;
  select sw.*, pf.name as from_name, pt.name as to_name, sc.date as sdate, sc.shift as sshift
    into s
  from public.swaps sw
  join public.profiles pf on pf.id = sw.from_staff
  join public.profiles pt on pt.id = sw.to_staff
  join public.schedule sc on sc.id = sw.entry_id
  where sw.id = p_id;
  if not found then raise exception 'Permohonan tidak dijumpai'; end if;
  if s.status <> 'pending_peer' then raise exception 'Permohonan tidak sah'; end if;
  if s.to_staff <> auth.uid() then raise exception 'Akses ditolak'; end if;

  update public.swaps
     set status = (case when p_accept then 'pending_manager' else 'declined' end), t_peer = now()
   where id = p_id;

  if p_accept then
    insert into public.notifications (user_id, msg)
    values (s.from_staff, '✅ ' || s.to_name || ' BERESETUJU menerima syif anda (' || to_char(s.sdate,'DD/MM/YYYY') || ') — menunggu kelulusan manager.');
    insert into public.notifications (user_id, msg)
    select p.id, '🔄 Pertukaran syif menunggu kelulusan anda: ' || s.from_name || ' ➜ ' || s.to_name ||
                 ' (' || to_char(s.sdate,'DD/MM/YYYY') || ', ' || (case when s.sshift='morning' then 'Pagi' else 'Petang' end) || ').'
    from public.profiles p
    where p.role in ('manager','admin') and p.active and p.id <> auth.uid();
  else
    insert into public.notifications (user_id, msg)
    values (s.from_staff, '❌ ' || s.to_name || ' telah menolak permohonan tukar syif anda.');
  end if;
  insert into public.audit (action, detail)
  values ('swap_peer_' || (case when p_accept then 'accept' else 'decline' end), s.from_name || ' ➜ ' || s.to_name);
end $$;

-- Manager lulus/tolak pertukaran (PRD 5.4 — peringkat 2; jadual dikemaskini automatik)
create or replace function public.decide_swap(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public, auth as $$ declare s record;
begin
  if auth.uid() is null or not public.is_manager() then raise exception 'Akses ditolak'; end if;
  select sw.*, pf.name as from_name, pt.name as to_name,
         e.staff_id as entry_staff, e.date as sdate
    into s
  from public.swaps sw
  join public.profiles pf on pf.id = sw.from_staff
  join public.profiles pt on pt.id = sw.to_staff
  join public.schedule e on e.id = sw.entry_id
  where sw.id = p_id;
  if not found then raise exception 'Permohonan tidak dijumpai'; end if;
  if s.status <> 'pending_manager' then raise exception 'Permohonan tidak sah'; end if;

  if p_approve then
    if s.entry_staff <> s.from_staff then raise exception 'Syif telah berubah — permohonan tidak boleh diluluskan'; end if;
    if s.exchange_entry_id is null then
      update public.schedule set staff_id = s.to_staff where id = s.entry_id;
    else
      if not exists (select 1 from public.schedule where id = s.exchange_entry_id and staff_id = s.to_staff) then
        raise exception 'Syif rakan telah berubah — permohonan tidak boleh diluluskan';
      end if;
      update public.schedule
         set staff_id = (case when id = s.entry_id then s.to_staff else s.from_staff end)
       where id in (s.entry_id, s.exchange_entry_id);
    end if;
    update public.swaps set status = 'approved', t_mgr = now(), decided_by = auth.uid() where id = p_id;
    insert into public.notifications (user_id, msg)
    values (s.from_staff, '✅ Pertukaran syif DILULUSKAN — jadual rasmi dikemaskini (' || to_char(s.sdate,'DD/MM/YYYY') || ').'),
           (s.to_staff,   '✅ Pertukaran syif DILULUSKAN — jadual rasmi dikemaskini (' || to_char(s.sdate,'DD/MM/YYYY') || ').');
  else
    update public.swaps set status = 'rejected', t_mgr = now(), decided_by = auth.uid() where id = p_id;
    insert into public.notifications (user_id, msg)
    values (s.from_staff, '❌ Pertukaran syif tidak diluluskan oleh manager.'),
           (s.to_staff,   '❌ Pertukaran syif tidak diluluskan oleh manager.');
  end if;
  insert into public.audit (action, detail)
  values ('swap_mgr_' || (case when p_approve then 'approve' else 'reject' end), s.from_name || ' ➜ ' || s.to_name);
end $$;

-- Kiraan tempahan per slot untuk staff (tanpa nama — PRD 5.2)
create or replace function public.slot_counts(p_month text) returns table(d date, shift text, n int)
language sql stable security definer set search_path = public as $$   select b.date, b.shift, count(*)::int
  from public.bookings b
  where b.status in ('pending','approved') and to_char(b.date, 'YYYY-MM') = p_month
  group by b.date, b.shift;
 $$;