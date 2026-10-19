-- companies and their members (andaime new --tenant)
create table companies (
    id uuid primary key,
    name text not null,
    created_at timestamptz not null
);

create table memberships (
    company_id uuid not null references companies (id),
    user_id bigint not null,
    role text not null,
    joined_at timestamptz not null,
    primary key (company_id, user_id)
);
