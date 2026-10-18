-- users (andaime generate resource)
create table users (
    id bigserial primary key,
    name text not null,
    email text not null unique
);
