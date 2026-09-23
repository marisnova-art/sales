-- =====================================================================
--  Personal Sales Planner — Supabase SQL Schema
--  Supabase 대시보드 → SQL Editor → New query → 전체 붙여넣기 → Run
--  여러 번 실행해도 안전하도록 작성되어 있습니다(if not exists).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 분류 테이블: 사업 유형 / 카테고리 / 판매 채널 (사용자가 직접 추가)
-- ---------------------------------------------------------------------
create table if not exists public.business_types (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  color       text,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  color       text,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.channels (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  color       text,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 수익 항목 (Revenue Item)
--  수량(qty_*)은 1년 계획 기준. 구독 모델은 "평균 구독자 수"(월 과금 × 12)
-- ---------------------------------------------------------------------
create table if not exists public.revenue_items (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  business_type_id  uuid references public.business_types(id) on delete set null,
  category_id       uuid references public.categories(id)     on delete set null,
  channel_id        uuid references public.channels(id)       on delete set null,
  revenue_model     text not null default 'per_item'
                    check (revenue_model in ('one_time','per_item','per_project','commission',
                                             'subscription','license','b2b_contract','other')),
  status            text not null default 'idea'
                    check (status in ('idea','planning','production','ready','active','paused','completed')),
  launch_date       date,
  description       text,
  notes             text,
  price             numeric(14,2) not null default 0 check (price >= 0),
  currency          text not null default 'KRW' check (currency in ('KRW','USD','EUR','JPY')),
  qty_min           numeric(14,2) not null default 0,
  qty_expected      numeric(14,2) not null default 0,
  qty_target        numeric(14,2) not null default 0,
  qty_max           numeric(14,2) not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 비용: 금액(amount) 또는 비율(percent, 매출 대비 %)
--  basis  = unit(판매 1단위당, 변동비) | fixed(고정비)
--  recurrence = monthly(매월 발생) | once(1회, 출시월에 반영)  — fixed일 때만 사용
-- ---------------------------------------------------------------------
create table if not exists public.costs (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references public.revenue_items(id) on delete cascade,
  cost_type   text not null default 'other'
              check (cost_type in ('production','platform','payment','advertising','outsourcing',
                                   'shipping','packaging','fixed','other')),
  label       text,
  mode        text not null default 'amount'  check (mode in ('amount','percent')),
  basis       text not null default 'unit'    check (basis in ('unit','fixed')),
  recurrence  text not null default 'monthly' check (recurrence in ('monthly','once')),
  value       numeric(14,2) not null default 0,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 월별 판매 계획 (항목 × 연 × 월 = 1행)
-- ---------------------------------------------------------------------
create table if not exists public.sales_plans (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references public.revenue_items(id) on delete cascade,
  year        int  not null check (year between 2000 and 2100),
  month       int  not null check (month between 1 and 12),
  quantity    numeric(14,2) not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (item_id, year, month)
);

-- ---------------------------------------------------------------------
-- 실제 매출 기록 (금액은 항목 통화 기준)
-- ---------------------------------------------------------------------
create table if not exists public.actual_sales (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references public.revenue_items(id) on delete cascade,
  sale_date   date not null,
  quantity    numeric(14,2) not null default 0,
  unit_price  numeric(14,2) not null default 0,
  amount      numeric(14,2) not null default 0,
  extra_cost  numeric(14,2) not null default 0,
  channel_id  uuid references public.channels(id) on delete set null,
  memo        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 설정 (1행만 존재: id = 1)
--  fx_rates: 통화 1단위당 원화 금액 (사용자가 직접 입력)
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  id              int primary key default 1 check (id = 1),
  annual_target   numeric(16,2) not null default 0,
  monthly_target  numeric(16,2),
  base_currency   text not null default 'KRW' check (base_currency in ('KRW','USD','EUR','JPY')),
  fx_rates        jsonb not null default '{"KRW":1,"USD":1380,"EUR":1500,"JPY":9.3}'::jsonb,
  preferences     jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 인덱스
-- ---------------------------------------------------------------------
create index if not exists idx_items_category on public.revenue_items(category_id);
create index if not exists idx_items_channel  on public.revenue_items(channel_id);
create index if not exists idx_items_status   on public.revenue_items(status);
create index if not exists idx_costs_item     on public.costs(item_id);
create index if not exists idx_plans_item_ym  on public.sales_plans(item_id, year, month);
create index if not exists idx_sales_item     on public.actual_sales(item_id);
create index if not exists idx_sales_date     on public.actual_sales(sale_date);

-- ---------------------------------------------------------------------
-- updated_at 자동 갱신
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['revenue_items','sales_plans','actual_sales','settings'] loop
    execute format('drop trigger if exists trg_%1$s_updated on public.%1$s', t);
    execute format('create trigger trg_%1$s_updated before update on public.%1$s
                    for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 접근 권한 (1인 사용, 로그인 없음)
--  ⚠ anon key를 가진 사람은 누구나 이 데이터에 접근할 수 있습니다.
--    앱 주소와 키를 공개 저장소·공개 페이지에 올리지 마세요.
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.business_types, public.categories, public.channels, public.revenue_items,
  public.costs, public.sales_plans, public.actual_sales, public.settings
to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['business_types','categories','channels','revenue_items',
                           'costs','sales_plans','actual_sales','settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "single_user_all" on public.%I', t);
    execute format('create policy "single_user_all" on public.%I for all to anon, authenticated
                    using (true) with check (true)', t);
  end loop;
end $$;
