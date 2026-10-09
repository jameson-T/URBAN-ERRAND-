-- =====================================================================
-- URBAN ERRAND — SUPABASE / POSTGRES SCHEMA
-- Consider It Done.
--
-- This schema maps the data model used by the Urban Errand prototype
-- (currently simulated in browser localStorage) onto real Postgres
-- tables, with Row Level Security so each role only ever sees what
-- it's allowed to.
--
-- HOW TO USE
--   1. Create a Supabase project.
--   2. Open the SQL Editor and run this file top to bottom.
--      (Safe to re-run: everything uses IF NOT EXISTS / OR REPLACE.)
--   3. Supabase Auth (auth.users) is used for login — this file
--      creates a `profiles` table keyed to auth.users.id rather than
--      a separate auth system, since Supabase Auth already handles
--      password hashing, sessions, and email/phone verification.
--   4. Nothing in this file talks to Paystack/Flutterwave directly —
--      that happens in a server-side Edge Function (webhook handler)
--      that calls the `mark_commission_paid()` function below after
--      verifying the provider's signature. Never call that function
--      from the browser.
--
-- WHAT THIS DOES NOT DO
--   - It does not store any payment-provider secret. Those live in
--     Supabase Edge Function environment variables, never in a table.
--   - It does not implement the webhook endpoint itself — that's a
--     small Edge Function (Deno/TypeScript), not SQL. Ask me for that
--     once you've picked Paystack or Flutterwave and have test keys.
-- =====================================================================

-- ---------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
do $$ begin
  create type user_role as enum ('buyer','agent_runner','agent_rider','seller','admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type errand_status as enum (
    'REQUESTED','AGENT_SELECTED','AGENT_CONFIRMED',
    'MERCHANT_CONFIRMATION_REQUIRED','MERCHANT_CONFIRMED','PREPARING','READY_FOR_PICKUP',
    'GOING_TO_SELLER','ARRIVED_AT_SELLER','AGENT_ARRIVED','ITEM_CONFIRMED',
    'PRICE_CHANGE_REQUESTED','PRICE_CHANGE_REJECTED',
    'PICKED_UP','IN_TRANSIT','ARRIVED_AT_CUSTOMER','DELIVERED','PAYMENT_CONFIRMED','COMPLETED',
    'CANCELLED','ITEM_UNAVAILABLE','CUSTOMER_UNAVAILABLE','AGENT_CANCELLED','DISPUTED'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type commission_status as enum ('PENDING','PAYMENT_INITIATED','PAID','PAYMENT_FAILED','REQUIRES_REVIEW');
exception when duplicate_object then null; end $$;

do $$ begin
  create type message_type as enum ('text','image','voice','system');
exception when duplicate_object then null; end $$;

do $$ begin
  create type dispute_status as enum ('Open','Under Review','Awaiting Response','Resolved','Closed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

-- =====================================================================
-- PROFILES  (one row per auth.users row — shared columns for all roles)
-- =====================================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null,
  full_name text,                 -- buyer / agent display name
  phone text,
  email text,
  address text,
  city text,
  suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_profiles_role on profiles(role);

drop trigger if exists trg_profiles_updated on profiles;
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- Needed early: referenced by merchant_credentials RLS policies below,
-- and again by the main RLS section further down.
create or replace function is_admin() returns boolean language sql stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;


-- ---------------------------------------------------------------------
-- AGENT PROFILES  (extends profiles where role in agent_runner/agent_rider)
-- ---------------------------------------------------------------------
create table if not exists agent_profiles (
  user_id uuid primary key references profiles(id) on delete cascade,
  agent_type text not null check (agent_type in ('runner','rider')),
  transport_type text,                 -- e.g. Motorcycle, Car, Bicycle, E-bike (riders only)
  vehicle_details text,
  verification_status text not null default 'Pending Verification'
    check (verification_status in ('Pending Verification','Verified','Rejected')),
  rating numeric(2,1) not null default 5.0,
  completed_errands int not null default 0,
  cancellation_rate numeric(5,2) not null default 0,
  completion_rate numeric(5,2) not null default 100,
  avg_response_min int,
  service_radius_km numeric(5,2) not null default 5,
  online boolean not null default false,
  current_lat double precision,
  current_lng double precision,
  location_updated_at timestamptz,
  member_since timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_agent_profiles_updated on agent_profiles;
create trigger trg_agent_profiles_updated before update on agent_profiles
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- MERCHANT PROFILES  (extends profiles where role = seller)
-- ---------------------------------------------------------------------
create table if not exists merchant_profiles (
  user_id uuid primary key references profiles(id) on delete cascade,
  business_name text not null,
  owner_name text,
  category text,
  description text,
  logo_url text,
  cover_url text,
  whatsapp text,
  opening_time text,
  closing_time text,
  is_open boolean not null default true,
  -- Wider than Agent verification on purpose: a Merchant can be reviewed
  -- and approved without every formal document (see merchant_credentials
  -- below). Agents keep their own stricter status set — do not reuse this
  -- enum for agent_profiles.verification_status.
  verification_status text not null default 'Pending Verification'
    check (verification_status in (
      'Pending Verification','Verified','Partially Verified',
      'Needs More Information','Rejected'
    )),
  rating numeric(2,1) not null default 5.0,
  lat double precision,
  lng double precision,
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_merchant_profiles_updated on merchant_profiles;
create trigger trg_merchant_profiles_updated before update on merchant_profiles
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- MERCHANT CREDENTIALS  (optional business documents — CAC, permit, tax ID)
--
-- A merchant can legitimately not have these (sole proprietors, market
-- vendors, Instagram businesses). `declared = 'no'` is a real answer, not
-- a missing upload — that's why `status` distinguishes NOT_AVAILABLE from
-- a credential the merchant said they'd submit but hasn't yet.
-- This table is Merchant-only. Do not reuse it for Agent documents —
-- Agent identity verification stays mandatory and lives in whatever
-- Agent-document structure already exists.
-- ---------------------------------------------------------------------
do $$ begin
  create type credential_status as enum (
    'NOT_AVAILABLE','PENDING_REVIEW','SUBMITTED','VERIFIED','REJECTED'
  );
exception when duplicate_object then null; end $$;

create table if not exists merchant_credentials (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references merchant_profiles(user_id) on delete cascade,
  credential_key text not null check (credential_key in ('cac','businessPermit','taxId')),
  declared text check (declared in ('yes','no')),   -- did the merchant say they have it?
  document_url text,
  status credential_status not null default 'NOT_AVAILABLE',
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (merchant_id, credential_key)
);
create index if not exists idx_merchant_credentials_merchant on merchant_credentials(merchant_id);

drop trigger if exists trg_merchant_credentials_updated on merchant_credentials;
create trigger trg_merchant_credentials_updated before update on merchant_credentials
  for each row execute function set_updated_at();

alter table merchant_credentials enable row level security;

drop policy if exists merchant_credentials_select on merchant_credentials;
create policy merchant_credentials_select on merchant_credentials for select
  using (merchant_id = auth.uid() or is_admin());
drop policy if exists merchant_credentials_write on merchant_credentials;
create policy merchant_credentials_write on merchant_credentials for insert
  with check (merchant_id = auth.uid());
drop policy if exists merchant_credentials_update on merchant_credentials;
create policy merchant_credentials_update on merchant_credentials for update
  using (merchant_id = auth.uid() or is_admin());

-- =====================================================================
-- PRODUCTS
-- =====================================================================
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references merchant_profiles(user_id) on delete cascade,
  name text not null,
  description text,
  price numeric(12,2) not null check (price >= 0),
  category text,
  image_url text,
  stock_quantity int not null default 0,
  is_available boolean not null default true,
  sku text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_products_merchant on products(merchant_id);

drop trigger if exists trg_products_updated on products;
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at();

-- =====================================================================
-- ERRANDS  (the core order record)
-- =====================================================================
create table if not exists errands (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references profiles(id),
  merchant_id uuid references merchant_profiles(user_id),
  agent_id uuid references agent_profiles(user_id),

  item_name text not null,
  description text,
  quantity int not null default 1,
  item_size text check (item_size in ('light','medium','heavy')),
  reference_image_url text,
  special_instructions text,

  pickup_address text,
  delivery_address text,
  recipient_name text,
  recipient_phone text,

  estimated_price numeric(12,2) not null default 0,
  agent_fee numeric(12,2) not null default 0,

  status errand_status not null default 'REQUESTED',
  agent_confirmed boolean not null default false,

  -- price change sub-state (mirrors the JSON blob used in the prototype)
  price_change_estimated numeric(12,2),
  price_change_actual numeric(12,2),
  price_change_status text check (price_change_status in ('requested','approved','rejected')),
  price_change_by text check (price_change_by in ('agent','merchant')),

  unavailable_reason text,
  unavailable_alternative text,
  unavailable_alt_price numeric(12,2),

  delivery_otp text,
  pickup_photo_url text,
  delivery_photo_url text,
  handoff_photo_url text,
  handoff_at timestamptz,

  payment_confirmed boolean not null default false,
  rating int check (rating between 1 and 5),
  review text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_errands_buyer on errands(buyer_id);
create index if not exists idx_errands_merchant on errands(merchant_id);
create index if not exists idx_errands_agent on errands(agent_id);
create index if not exists idx_errands_status on errands(status);
create index if not exists idx_errands_created on errands(created_at);

drop trigger if exists trg_errands_updated on errands;
create trigger trg_errands_updated before update on errands
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- ERRAND STATUS HISTORY  (append-only audit of every transition)
-- ---------------------------------------------------------------------
create table if not exists errand_status_history (
  id uuid primary key default gen_random_uuid(),
  errand_id uuid not null references errands(id) on delete cascade,
  status errand_status not null,
  actor_id uuid references profiles(id),
  actor_role user_role,
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists idx_history_errand on errand_status_history(errand_id);

-- ---------------------------------------------------------------------
-- Who is allowed to move an errand to which status.
-- Enforced in a trigger so a compromised/buggy client can't skip steps.
-- ---------------------------------------------------------------------
create or replace function validate_errand_transition()
returns trigger language plpgsql as $$
declare
  actor_role user_role;
begin
  if new.status = old.status then
    return new; -- no-op update (e.g. editing notes) — allowed
  end if;

  select role into actor_role from profiles where id = auth.uid();

  -- Admins may always correct state (the app layer still requires a reason,
  -- recorded via log_admin_action()).
  if actor_role = 'admin' then
    return new;
  end if;

  -- Buyer-permitted transitions
  if actor_role = 'buyer' and new.buyer_id = auth.uid() then
    if old.status = 'ARRIVED_AT_CUSTOMER' and new.status = 'DELIVERED' then return new; end if;
    if old.status = 'DELIVERED' and new.status = 'PAYMENT_CONFIRMED' then return new; end if;
    if new.status = 'PAYMENT_CONFIRMED' and new.status in ('COMPLETED') then return new; end if;
    if old.status in ('PAYMENT_CONFIRMED') and new.status = 'COMPLETED' then return new; end if;
    if new.status = 'CANCELLED' and old.status in ('REQUESTED','AGENT_SELECTED') then return new; end if;
    if old.status = 'PRICE_CHANGE_REQUESTED' and new.status in ('MERCHANT_CONFIRMED','AGENT_CONFIRMED') then return new; end if;
  end if;

  -- Agent-permitted transitions (only on their own assigned errand)
  if actor_role in ('agent_runner','agent_rider') and new.agent_id = auth.uid() then
    if old.status = 'AGENT_SELECTED' and new.status = 'AGENT_CONFIRMED' then return new; end if;
    if old.status in ('AGENT_CONFIRMED','READY_FOR_PICKUP') and new.status in ('GOING_TO_SELLER','MERCHANT_CONFIRMATION_REQUIRED') then return new; end if;
    if old.status = 'GOING_TO_SELLER' and new.status in ('ARRIVED_AT_SELLER','AGENT_ARRIVED') then return new; end if;
    if old.status = 'ARRIVED_AT_SELLER' and new.status in ('ITEM_CONFIRMED','PRICE_CHANGE_REQUESTED','ITEM_UNAVAILABLE') then return new; end if;
    if old.status = 'ITEM_CONFIRMED' and new.status = 'PICKED_UP' then return new; end if;
    if old.status = 'PICKED_UP' and new.status = 'IN_TRANSIT' then return new; end if;
    if old.status = 'IN_TRANSIT' and new.status = 'ARRIVED_AT_CUSTOMER' then return new; end if;
    if new.status = 'AGENT_CANCELLED' then return new; end if;
  end if;

  -- Merchant-permitted transitions (only on their own store's errand)
  if actor_role = 'seller' and new.merchant_id = auth.uid() then
    if old.status = 'MERCHANT_CONFIRMATION_REQUIRED' and new.status in ('MERCHANT_CONFIRMED','PRICE_CHANGE_REQUESTED','ITEM_UNAVAILABLE') then return new; end if;
    if old.status = 'MERCHANT_CONFIRMED' and new.status = 'PREPARING' then return new; end if;
    if old.status = 'PREPARING' and new.status = 'READY_FOR_PICKUP' then return new; end if;
    if old.status = 'AGENT_ARRIVED' and new.status = 'PICKED_UP' then return new; end if;
  end if;

  raise exception 'Invalid status transition from % to % for role %', old.status, new.status, actor_role;
end; $$;

drop trigger if exists trg_validate_transition on errands;
create trigger trg_validate_transition before update of status on errands
  for each row execute function validate_errand_transition();

-- Automatically log every transition
create or replace function log_errand_transition()
returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status then
    insert into errand_status_history (errand_id, status, actor_id, actor_role, notes)
    values (new.id, new.status, auth.uid(), (select role from profiles where id = auth.uid()), null);
  end if;
  return new;
end; $$;

drop trigger if exists trg_log_transition on errands;
create trigger trg_log_transition after update of status on errands
  for each row execute function log_errand_transition();

-- =====================================================================
-- MESSAGES  (per-errand chat shared by buyer / agent / merchant)
-- =====================================================================
create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  errand_id uuid not null references errands(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  sender_role user_role not null,
  type message_type not null default 'text',
  body text,                       -- text content
  attachment_url text,             -- image message
  voice_duration_sec int,          -- voice message
  voice_url text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_messages_errand on messages(errand_id, created_at);

-- =====================================================================
-- NOTIFICATIONS
-- =====================================================================
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null,
  message text not null,
  type text not null default 'system',
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_user on notifications(user_id, read);

-- =====================================================================
-- COMMISSION ENGINE
-- =====================================================================

-- Versioned rate config — a rate change never rewrites historical commissions,
-- because each commission row stores the rate it was actually calculated at.
create table if not exists commission_rate_config (
  version int primary key,
  rate numeric(5,4) not null check (rate >= 0 and rate <= 1),
  effective_from timestamptz not null default now()
);
insert into commission_rate_config (version, rate)
  values (1, 0.20)
  on conflict (version) do nothing;

create table if not exists agent_commissions (
  id uuid primary key default gen_random_uuid(),
  errand_id uuid not null unique references errands(id),   -- UNIQUE = one commission per errand
  agent_id uuid not null references agent_profiles(user_id),
  agent_fee numeric(12,2) not null,
  commission_rate numeric(5,4) not null,
  rate_version int not null references commission_rate_config(version),
  commission_amount numeric(12,2) not null,
  currency text not null default 'NGN',
  status commission_status not null default 'PENDING',
  payment_reference text,
  payment_transaction_id text,
  initiated_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_commissions_agent on agent_commissions(agent_id, status);
create unique index if not exists idx_commissions_payment_ref on agent_commissions(payment_reference)
  where payment_reference is not null;  -- catches duplicate provider references

drop trigger if exists trg_commissions_updated on agent_commissions;
create trigger trg_commissions_updated before update on agent_commissions
  for each row execute function set_updated_at();

-- Payment attempts / provider events — one commission can have several
-- attempts (retry after a failure), so this is kept separate from the
-- commission record itself.
create table if not exists commission_payments (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references agent_commissions(id) on delete cascade,
  agent_id uuid not null references agent_profiles(user_id),
  amount numeric(12,2) not null,
  provider text not null,                 -- 'paystack' | 'flutterwave'
  provider_reference text not null,
  transaction_id text,
  status commission_status not null default 'PAYMENT_INITIATED',
  raw_webhook_payload jsonb,               -- store the verified payload for audit
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_payments_commission on commission_payments(commission_id);
create unique index if not exists idx_payments_provider_ref on commission_payments(provider, provider_reference);

drop trigger if exists trg_payments_updated on commission_payments;
create trigger trg_payments_updated before update on commission_payments
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- Auto-create exactly one commission record when an errand completes.
-- ---------------------------------------------------------------------
create or replace function create_commission_on_completion()
returns trigger language plpgsql as $$
declare
  current_rate numeric(5,4);
  current_version int;
  amount numeric(12,2);
begin
  if new.status = 'COMPLETED' and old.status is distinct from 'COMPLETED' and new.agent_id is not null then
    select version, rate into current_version, current_rate
      from commission_rate_config order by version desc limit 1;

    amount := round(new.agent_fee * current_rate);

    insert into agent_commissions (errand_id, agent_id, agent_fee, commission_rate, rate_version, commission_amount, status)
    values (new.id, new.agent_id, new.agent_fee, current_rate, current_version, amount,
            case when amount <= 0 then 'PAID' else 'PENDING' end)
    on conflict (errand_id) do nothing;  -- belt-and-braces against duplicate triggers/retries
  end if;
  return new;
end; $$;

drop trigger if exists trg_create_commission on errands;
create trigger trg_create_commission after update of status on errands
  for each row execute function create_commission_on_completion();

-- ---------------------------------------------------------------------
-- Server-side function the PAYMENT WEBHOOK calls after verifying the
-- provider's signature. This is the ONLY way a commission becomes PAID —
-- never call this from client code, and never expose it to anon/authenticated
-- roles (grant execute only to the service_role used by the Edge Function).
-- ---------------------------------------------------------------------
create or replace function mark_commission_paid(
  p_commission_id uuid,
  p_provider text,
  p_provider_reference text,
  p_transaction_id text,
  p_amount numeric,
  p_raw_payload jsonb
) returns void language plpgsql security definer as $$
declare
  c agent_commissions%rowtype;
begin
  select * into c from agent_commissions where id = p_commission_id for update;
  if not found then
    raise exception 'Commission % not found', p_commission_id;
  end if;
  if c.status = 'PAID' then
    return; -- idempotent: webhook retried for an already-settled commission
  end if;
  if p_amount <> c.commission_amount then
    update agent_commissions set status = 'REQUIRES_REVIEW', updated_at = now() where id = p_commission_id;
    insert into commission_payments (commission_id, agent_id, amount, provider, provider_reference, transaction_id, status, raw_webhook_payload)
      values (p_commission_id, c.agent_id, p_amount, p_provider, p_provider_reference, p_transaction_id, 'REQUIRES_REVIEW', p_raw_payload);
    raise exception 'Amount mismatch: expected %, got %', c.commission_amount, p_amount;
  end if;

  update agent_commissions
    set status = 'PAID', payment_reference = p_provider_reference,
        payment_transaction_id = p_transaction_id, paid_at = now(), updated_at = now()
    where id = p_commission_id;

  insert into commission_payments (commission_id, agent_id, amount, provider, provider_reference, transaction_id, status, verified_at, raw_webhook_payload)
    values (p_commission_id, c.agent_id, p_amount, p_provider, p_provider_reference, p_transaction_id, 'PAID', now(), p_raw_payload);
end; $$;

-- ---------------------------------------------------------------------
-- Block an agent from going online while they owe commission.
-- This is the server-side guarantee that Task 2 asks for — the frontend
-- toggle is advisory only; this trigger is what actually enforces it.
-- ---------------------------------------------------------------------
create or replace function enforce_commission_before_online()
returns trigger language plpgsql as $$
begin
  if new.online = true and old.online = false then
    if exists (
      select 1 from agent_commissions
      where agent_id = new.user_id
        and status in ('PENDING','PAYMENT_INITIATED','PAYMENT_FAILED','REQUIRES_REVIEW')
    ) then
      raise exception 'Agent % has outstanding commission and cannot go online', new.user_id;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_enforce_commission on agent_profiles;
create trigger trg_enforce_commission before update of online on agent_profiles
  for each row execute function enforce_commission_before_online();

-- =====================================================================
-- DISPUTES
-- =====================================================================
create table if not exists disputes (
  id uuid primary key default gen_random_uuid(),
  errand_id uuid references errands(id),
  reporting_user_id uuid references profiles(id),
  category text not null,
  description text,
  assigned_admin_id uuid references profiles(id),
  status dispute_status not null default 'Open',
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_disputes_status on disputes(status);

drop trigger if exists trg_disputes_updated on disputes;
create trigger trg_disputes_updated before update on disputes
  for each row execute function set_updated_at();

-- =====================================================================
-- ADMIN AUDIT LOG  (insert-only — no UPDATE/DELETE policy is granted)
-- =====================================================================
create table if not exists admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references profiles(id),
  action text not null,
  entity_type text not null,
  entity_id text not null,
  reason text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_admin on admin_audit_logs(admin_id, created_at);

create or replace function log_admin_action(
  p_action text, p_entity_type text, p_entity_id text,
  p_reason text, p_before jsonb, p_after jsonb
) returns void language plpgsql security definer as $$
begin
  if (select role from profiles where id = auth.uid()) <> 'admin' then
    raise exception 'Only admins may write audit records';
  end if;
  insert into admin_audit_logs (admin_id, action, entity_type, entity_id, reason, before_data, after_data)
  values (auth.uid(), p_action, p_entity_type, p_entity_id, p_reason, p_before, p_after);
end; $$;

-- =====================================================================
-- AGENT LIVE LOCATION  (separate, short-lived table — not profile history)
-- Only written by the agent themself while they have a consented, active
-- errand; only readable by that errand's buyer, that agent, and admins.
-- =====================================================================
create table if not exists agent_locations (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references agent_profiles(user_id),
  errand_id uuid references errands(id),
  lat double precision not null,
  lng double precision not null,
  accuracy_m numeric,
  created_at timestamptz not null default now()
);
create index if not exists idx_locations_agent_time on agent_locations(agent_id, created_at desc);
create index if not exists idx_locations_errand on agent_locations(errand_id, created_at desc);

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table profiles enable row level security;
alter table agent_profiles enable row level security;
alter table merchant_profiles enable row level security;
alter table products enable row level security;
alter table errands enable row level security;
alter table errand_status_history enable row level security;
alter table messages enable row level security;
alter table notifications enable row level security;
alter table agent_commissions enable row level security;
alter table commission_payments enable row level security;
alter table disputes enable row level security;
alter table admin_audit_logs enable row level security;
alter table agent_locations enable row level security;
alter table commission_rate_config enable row level security;

-- ---- profiles ----
drop policy if exists profiles_self_select on profiles;
create policy profiles_self_select on profiles for select
  using (id = auth.uid() or is_admin());
drop policy if exists profiles_self_update on profiles;
create policy profiles_self_update on profiles for update
  using (id = auth.uid() or is_admin());
drop policy if exists profiles_self_insert on profiles;
create policy profiles_self_insert on profiles for insert
  with check (id = auth.uid());

-- ---- agent_profiles: public can browse basic agent cards; only the
-- agent (or admin) can write ----
drop policy if exists agent_profiles_public_select on agent_profiles;
create policy agent_profiles_public_select on agent_profiles for select using (true);
drop policy if exists agent_profiles_self_update on agent_profiles;
create policy agent_profiles_self_update on agent_profiles for update
  using (user_id = auth.uid() or is_admin());
drop policy if exists agent_profiles_self_insert on agent_profiles;
create policy agent_profiles_self_insert on agent_profiles for insert
  with check (user_id = auth.uid());

-- ---- merchant_profiles: public store browsing; only the merchant writes ----
drop policy if exists merchant_profiles_public_select on merchant_profiles;
create policy merchant_profiles_public_select on merchant_profiles for select using (true);
drop policy if exists merchant_profiles_self_update on merchant_profiles;
create policy merchant_profiles_self_update on merchant_profiles for update
  using (user_id = auth.uid() or is_admin());
drop policy if exists merchant_profiles_self_insert on merchant_profiles;
create policy merchant_profiles_self_insert on merchant_profiles for insert
  with check (user_id = auth.uid());

-- ---- products: public reads available items; merchant manages own ----
drop policy if exists products_public_select on products;
create policy products_public_select on products for select using (true);
drop policy if exists products_merchant_write on products;
create policy products_merchant_write on products for all
  using (merchant_id = auth.uid() or is_admin())
  with check (merchant_id = auth.uid() or is_admin());

-- ---- errands: visible only to its buyer, assigned agent, assigned
-- merchant, or admin ----
drop policy if exists errands_participant_select on errands;
create policy errands_participant_select on errands for select
  using (buyer_id = auth.uid() or agent_id = auth.uid() or merchant_id = auth.uid() or is_admin());
drop policy if exists errands_buyer_insert on errands;
create policy errands_buyer_insert on errands for insert
  with check (buyer_id = auth.uid());
drop policy if exists errands_participant_update on errands;
create policy errands_participant_update on errands for update
  using (buyer_id = auth.uid() or agent_id = auth.uid() or merchant_id = auth.uid() or is_admin());

-- ---- errand_status_history: same visibility as the parent errand; insert-only via trigger ----
drop policy if exists history_participant_select on errand_status_history;
create policy history_participant_select on errand_status_history for select
  using (exists (
    select 1 from errands e where e.id = errand_id
      and (e.buyer_id = auth.uid() or e.agent_id = auth.uid() or e.merchant_id = auth.uid())
  ) or is_admin());

-- ---- messages: only the three parties on that errand ----
drop policy if exists messages_participant_select on messages;
create policy messages_participant_select on messages for select
  using (exists (
    select 1 from errands e where e.id = errand_id
      and (e.buyer_id = auth.uid() or e.agent_id = auth.uid() or e.merchant_id = auth.uid())
  ) or is_admin());
drop policy if exists messages_participant_insert on messages;
create policy messages_participant_insert on messages for insert
  with check (sender_id = auth.uid() and exists (
    select 1 from errands e where e.id = errand_id
      and (e.buyer_id = auth.uid() or e.agent_id = auth.uid() or e.merchant_id = auth.uid())
  ));

-- ---- notifications: only the owning user ----
drop policy if exists notifications_owner_select on notifications;
create policy notifications_owner_select on notifications for select
  using (user_id = auth.uid() or is_admin());
drop policy if exists notifications_owner_update on notifications;
create policy notifications_owner_update on notifications for update
  using (user_id = auth.uid());

-- ---- agent_commissions: agent sees own; admin sees all; no client UPDATE ----
drop policy if exists commissions_select on agent_commissions;
create policy commissions_select on agent_commissions for select
  using (agent_id = auth.uid() or is_admin());
-- deliberately no insert/update policy for authenticated/anon —
-- rows are only written by the triggers above and mark_commission_paid()
-- (SECURITY DEFINER), or by an admin action routed through log_admin_action().

-- ---- commission_payments: same visibility as the commission ----
drop policy if exists payments_select on commission_payments;
create policy payments_select on commission_payments for select
  using (agent_id = auth.uid() or is_admin());

-- ---- disputes: reporter + admin ----
drop policy if exists disputes_select on disputes;
create policy disputes_select on disputes for select
  using (reporting_user_id = auth.uid() or is_admin());
drop policy if exists disputes_insert on disputes;
create policy disputes_insert on disputes for insert
  with check (reporting_user_id = auth.uid());
drop policy if exists disputes_admin_update on disputes;
create policy disputes_admin_update on disputes for update using (is_admin());

-- ---- admin_audit_logs: admin read-only via policy; writes only via log_admin_action() ----
drop policy if exists audit_admin_select on admin_audit_logs;
create policy audit_admin_select on admin_audit_logs for select using (is_admin());

-- ---- agent_locations: the agent who owns it, the buyer on that active
-- errand, and admins — nobody else ----
drop policy if exists locations_write on agent_locations;
create policy locations_write on agent_locations for insert
  with check (agent_id = auth.uid());
drop policy if exists locations_select on agent_locations;
create policy locations_select on agent_locations for select
  using (
    agent_id = auth.uid()
    or is_admin()
    or exists (
      select 1 from errands e
      where e.id = errand_id and e.buyer_id = auth.uid()
        and e.status not in ('COMPLETED','CANCELLED','DELIVERED','PAYMENT_CONFIRMED')
    )
  );

-- ---- commission_rate_config: everyone can read current rate; only admin changes it ----
drop policy if exists rate_config_select on commission_rate_config;
create policy rate_config_select on commission_rate_config for select using (true);
drop policy if exists rate_config_admin_write on commission_rate_config;
create policy rate_config_admin_write on commission_rate_config for insert with check (is_admin());

-- =====================================================================
-- NOTES FOR WHOEVER WIRES THE APP UP TO THIS SCHEMA
-- =====================================================================
-- 1. Auth: use Supabase Auth (email/phone OTP or password) instead of the
--    prototype's "any password works" login. After a user confirms their
--    auth.users row, insert a matching `profiles` row with their chosen
--    role, then an `agent_profiles` or `merchant_profiles` row if relevant.
--
-- 2. Payments (Paystack/Flutterwave): create a Supabase Edge Function
--    (e.g. `commission-webhook`) that:
--      a. Verifies the request signature using the provider's secret
--         (stored as an Edge Function env var, never in this database).
--      b. Looks up the agent_commissions row by payment_reference.
--      c. Calls `mark_commission_paid(...)` with the verified amount.
--    Initiating payment (building the checkout link) is a second small
--    Edge Function that reads the PENDING commission and calls the
--    provider's "initialize transaction" API with your secret key.
--
-- 3. Realtime: Supabase Realtime can subscribe to `errands`, `messages`,
--    and `agent_locations` out of the box — this replaces the
--    localStorage "shared array" trick the prototype used.
--
-- 4. Location: only write to `agent_locations` while
--    `errands.status` is an active, non-terminal value, and stop as soon
--    as it reaches DELIVERED — don't keep a location history forever.
-- =====================================================================

-- =====================================================================
-- APPLICATION REVIEW  (Agent + Merchant verification with document review)
--
-- Replaces "click Verified" with a real review trail:
--   * every applicant has ONE application (applications)
--   * every uploaded file is a row (application_documents) pointing at a
--     PRIVATE storage object — never a public URL
--   * admins verify/reject each document, then approve/decline/request
--     resubmission through SECURITY DEFINER functions that enforce the
--     rules in the database (the browser cannot skip them)
--   * every step is written to application_events (insert-only)
--
-- Agent and Merchant required documents differ on purpose
-- (see required_document_types). Merchant CAC / permit / tax-ID live in
-- merchant_credentials above and are OPTIONAL — they never block approval.
-- =====================================================================
do $$ begin
  create type application_status as enum
    ('PENDING_REVIEW','UNDER_REVIEW','APPROVED','DECLINED','RESUBMISSION_REQUIRED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type document_review_status as enum ('NOT_REVIEWED','VERIFIED','REJECTED');
exception when duplicate_object then null; end $$;

create table if not exists applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null unique references profiles(id) on delete cascade,
  role user_role not null check (role in ('agent_runner','agent_rider','seller')),
  status application_status not null default 'PENDING_REVIEW',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references profiles(id),
  decision_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_applications_status on applications(status, submitted_at);

drop trigger if exists trg_applications_updated on applications;
create trigger trg_applications_updated before update on applications
  for each row execute function set_updated_at();

create table if not exists application_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications(id) on delete cascade,
  applicant_id uuid not null references profiles(id) on delete cascade,
  document_type text not null,
  storage_path text not null,            -- path inside the PRIVATE 'application-documents' bucket
  file_name text not null,
  file_type text not null check (file_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  file_size int not null check (file_size > 0 and file_size <= 5242880),
  status document_review_status not null default 'NOT_REVIEWED',
  rejection_reason text,
  viewed_at timestamptz,                 -- admin must open a document before reviewing it
  viewed_by uuid references profiles(id),
  uploaded_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references profiles(id),
  unique (application_id, document_type),
  check (status <> 'REJECTED' or coalesce(btrim(rejection_reason), '') <> '')
);
create index if not exists idx_app_docs_application on application_documents(application_id);

create table if not exists application_events (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references applications(id) on delete cascade,
  actor_id uuid references profiles(id),
  actor_role user_role,
  action text not null,                  -- APPLICATION_OPENED, DOCUMENT_VERIFIED, DOCUMENT_REJECTED, ...
  previous_status application_status,
  new_status application_status,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists idx_app_events_application on application_events(application_id, created_at);

alter table applications enable row level security;
alter table application_documents enable row level security;
alter table application_events enable row level security;

-- Applicants see only their own application; admins see all.
-- There is deliberately NO insert/update/delete policy on documents or
-- events: all writes go through the functions below.
drop policy if exists applications_select on applications;
create policy applications_select on applications for select
  using (applicant_id = auth.uid() or is_admin());
drop policy if exists applications_insert on applications;
create policy applications_insert on applications for insert
  with check (applicant_id = auth.uid() and status = 'PENDING_REVIEW');

drop policy if exists app_documents_select on application_documents;
create policy app_documents_select on application_documents for select
  using (applicant_id = auth.uid() or is_admin());

drop policy if exists app_events_select on application_events;
create policy app_events_select on application_events for select
  using (is_admin() or exists (
    select 1 from applications a where a.id = application_id and a.applicant_id = auth.uid()
  ));

-- ---------------------------------------------------------------------
-- Which documents are REQUIRED per role. Changing this list is how you
-- change the business rule — merchants intentionally do not require CAC.
-- ---------------------------------------------------------------------
create or replace function required_document_types(p_role user_role)
returns text[] language sql immutable as $$
  select case p_role
    when 'agent_runner' then array['Government ID','Selfie']
    when 'agent_rider'  then array['Government ID','Selfie','Vehicle Document']
    when 'seller'       then array['Government ID','Store Photo']
    else array[]::text[]
  end;
$$;

create or replace function log_application_event(
  p_application_id uuid, p_action text,
  p_prev application_status, p_new application_status, p_reason text
) returns void language plpgsql security definer as $$
begin
  insert into application_events (application_id, actor_id, actor_role, action, previous_status, new_status, reason)
  values (p_application_id, auth.uid(), (select role from profiles where id = auth.uid()), p_action, p_prev, p_new, p_reason);
end; $$;

create or replace function notify_user(p_user_id uuid, p_title text, p_message text, p_type text)
returns void language sql security definer as $$
  insert into notifications (user_id, title, message, type) values (p_user_id, p_title, p_message, p_type);
$$;

-- Applicant (or a replacement) uploads a file that is ALREADY in the private
-- bucket at p_storage_path. Resets review state for that document and, once
-- every requested fix is in, sends the application back to PENDING_REVIEW.
create or replace function submit_document(
  p_application_id uuid, p_document_type text, p_storage_path text,
  p_file_name text, p_file_type text, p_file_size int
) returns void language plpgsql security definer as $$
declare
  app applications%rowtype;
  rejected_left int;
  missing_left int;
begin
  select * into app from applications where id = p_application_id for update;
  if not found or app.applicant_id <> auth.uid() then
    raise exception 'Application not found';
  end if;
  if app.status in ('APPROVED','DECLINED') then
    raise exception 'This application is closed';
  end if;
  if p_storage_path not like auth.uid()::text || '/%' then
    raise exception 'File must be stored under your own folder';
  end if;

  insert into application_documents (application_id, applicant_id, document_type, storage_path, file_name, file_type, file_size)
  values (p_application_id, auth.uid(), p_document_type, p_storage_path, p_file_name, p_file_type, p_file_size)
  on conflict (application_id, document_type) do update
    set storage_path = excluded.storage_path, file_name = excluded.file_name,
        file_type = excluded.file_type, file_size = excluded.file_size,
        status = 'NOT_REVIEWED', rejection_reason = null,
        viewed_at = null, viewed_by = null, reviewed_at = null, reviewed_by = null,
        uploaded_at = now();

  if app.status = 'RESUBMISSION_REQUIRED' then
    select count(*) into rejected_left from application_documents
      where application_id = p_application_id and status = 'REJECTED';
    select count(*) into missing_left from unnest(required_document_types(app.role)) t
      where not exists (select 1 from application_documents d where d.application_id = p_application_id and d.document_type = t);
    if rejected_left = 0 and missing_left = 0 then
      update applications set status = 'PENDING_REVIEW', submitted_at = now() where id = p_application_id;
      perform log_application_event(p_application_id, 'RESUBMISSION_SUBMITTED', 'RESUBMISSION_REQUIRED', 'PENDING_REVIEW', 'Applicant uploaded replacement document(s)');
    end if;
  end if;
end; $$;

-- Admin opens a document (e.g. right before minting a signed URL for it).
create or replace function mark_document_viewed(p_document_id uuid)
returns void language plpgsql security definer as $$
begin
  if not is_admin() then raise exception 'Only admins may open applicant documents'; end if;
  update application_documents set viewed_at = now(), viewed_by = auth.uid() where id = p_document_id;
end; $$;

create or replace function open_application(p_application_id uuid)
returns void language plpgsql security definer as $$
begin
  if not is_admin() then raise exception 'Only admins may review applications'; end if;
  update applications set status = 'UNDER_REVIEW' where id = p_application_id and status = 'PENDING_REVIEW';
  if found then
    perform log_application_event(p_application_id, 'APPLICATION_OPENED', 'PENDING_REVIEW', 'UNDER_REVIEW', null);
  end if;
end; $$;

create or replace function review_document(
  p_document_id uuid, p_status document_review_status, p_reason text default null
) returns void language plpgsql security definer as $$
declare d application_documents%rowtype;
begin
  if not is_admin() then raise exception 'Only admins may review documents'; end if;
  if p_status = 'NOT_REVIEWED' then raise exception 'Choose VERIFIED or REJECTED'; end if;
  select * into d from application_documents where id = p_document_id for update;
  if not found then raise exception 'Document not found'; end if;
  if d.viewed_at is null then raise exception 'Open the document before reviewing it'; end if;
  if p_status = 'REJECTED' and coalesce(btrim(p_reason), '') = '' then
    raise exception 'A rejection reason is required';
  end if;
  update application_documents
    set status = p_status,
        rejection_reason = case when p_status = 'REJECTED' then p_reason else null end,
        reviewed_at = now(), reviewed_by = auth.uid()
    where id = p_document_id;
  perform log_application_event(d.application_id,
    case when p_status = 'VERIFIED' then 'DOCUMENT_VERIFIED' else 'DOCUMENT_REJECTED' end,
    null, null, p_reason);
end; $$;

-- The approval rule, enforced server-side:
--   every required document submitted, reviewed, VERIFIED, none REJECTED.
create or replace function approve_application(p_application_id uuid)
returns void language plpgsql security definer as $$
declare
  app applications%rowtype;
  req text[];
  t text;
  doc application_documents%rowtype;
begin
  if not is_admin() then raise exception 'Only admins may approve applications'; end if;
  select * into app from applications where id = p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if app.status in ('APPROVED','DECLINED') then raise exception 'Application already decided'; end if;
  req := required_document_types(app.role);
  foreach t in array req loop
    select * into doc from application_documents where application_id = p_application_id and document_type = t;
    if not found then raise exception 'Cannot approve: required document "%" has not been submitted', t; end if;
    if doc.status = 'REJECTED' then raise exception 'Cannot approve: "%" is rejected', t; end if;
    if doc.status <> 'VERIFIED' then raise exception 'Cannot approve: "%" has not been verified', t; end if;
  end loop;

  update applications
    set status = 'APPROVED', reviewed_by = auth.uid(), reviewed_at = now(), decision_reason = null
    where id = p_application_id;
  update agent_profiles set verification_status = 'Verified' where user_id = app.applicant_id;
  update merchant_profiles set verification_status = 'Verified' where user_id = app.applicant_id;
  perform log_application_event(p_application_id, 'APPLICATION_APPROVED', app.status, 'APPROVED', null);
  perform notify_user(app.applicant_id, 'Application Approved', 'Your Urban Errand application has been approved. Welcome to Urban Errand.', 'system');
end; $$;

create or replace function decline_application(p_application_id uuid, p_reason text)
returns void language plpgsql security definer as $$
declare app applications%rowtype;
begin
  if not is_admin() then raise exception 'Only admins may decline applications'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required to decline'; end if;
  select * into app from applications where id = p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if app.status in ('APPROVED','DECLINED') then raise exception 'Application already decided'; end if;
  update applications
    set status = 'DECLINED', reviewed_by = auth.uid(), reviewed_at = now(), decision_reason = p_reason
    where id = p_application_id;
  update agent_profiles set verification_status = 'Rejected' where user_id = app.applicant_id;
  update merchant_profiles set verification_status = 'Rejected' where user_id = app.applicant_id;
  perform log_application_event(p_application_id, 'APPLICATION_DECLINED', app.status, 'DECLINED', p_reason);
  perform notify_user(app.applicant_id, 'Application Declined', 'Your Urban Errand application was declined. Please review the reason provided: ' || p_reason, 'system');
end; $$;

create or replace function request_resubmission(p_application_id uuid)
returns void language plpgsql security definer as $$
declare
  app applications%rowtype;
  rejected_count int;
  missing_count int;
begin
  if not is_admin() then raise exception 'Only admins may request resubmission'; end if;
  select * into app from applications where id = p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if app.status in ('APPROVED','DECLINED') then raise exception 'Application already decided'; end if;
  select count(*) into rejected_count from application_documents
    where application_id = p_application_id and status = 'REJECTED';
  select count(*) into missing_count from unnest(required_document_types(app.role)) t
    where not exists (select 1 from application_documents d where d.application_id = p_application_id and d.document_type = t);
  if rejected_count = 0 and missing_count = 0 then
    raise exception 'Reject a document (with a reason) or wait for a missing required document first';
  end if;
  update applications set status = 'RESUBMISSION_REQUIRED', reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_application_id;
  perform log_application_event(p_application_id, 'RESUBMISSION_REQUESTED', app.status, 'RESUBMISSION_REQUIRED', null);
  perform notify_user(app.applicant_id, 'Resubmission Required', 'Additional verification is required. Please review the requested changes and resubmit your document.', 'action-required');
end; $$;

-- Functions check the caller themselves; just keep anonymous callers out.
revoke all on function submit_document(uuid, text, text, text, text, int) from public;
revoke all on function mark_document_viewed(uuid) from public;
revoke all on function open_application(uuid) from public;
revoke all on function review_document(uuid, document_review_status, text) from public;
revoke all on function approve_application(uuid) from public;
revoke all on function decline_application(uuid, text) from public;
revoke all on function request_resubmission(uuid) from public;
grant execute on function submit_document(uuid, text, text, text, text, int) to authenticated;
grant execute on function mark_document_viewed(uuid) to authenticated;
grant execute on function open_application(uuid) to authenticated;
grant execute on function review_document(uuid, document_review_status, text) to authenticated;
grant execute on function approve_application(uuid) to authenticated;
grant execute on function decline_application(uuid, text) to authenticated;
grant execute on function request_resubmission(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- PRIVATE document storage (Supabase Storage). Files live under
-- <applicant_id>/<filename>. The bucket is NOT public: admins view files
-- through short-lived signed URLs (supabase.storage.from(...).createSignedUrl)
-- minted with their own session; applicants can only touch their own folder.
-- Type and size limits are enforced by the bucket itself.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('application-documents', 'application-documents', false, 5242880,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'];

drop policy if exists app_docs_applicant_upload on storage.objects;
create policy app_docs_applicant_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'application-documents' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists app_docs_read on storage.objects;
create policy app_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'application-documents'
         and ((storage.foldername(name))[1] = auth.uid()::text or is_admin()));
-- No update/delete policies: files are replaced by uploading a new object
-- and calling submit_document(), which keeps the review history intact.
