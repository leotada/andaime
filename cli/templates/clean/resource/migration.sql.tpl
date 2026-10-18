-- {{pluralWords}} (andaime generate resource)
create table {{table}} (
    id bigserial primary key{{#fields}},
    {{column}} {{sqlType}}{{/fields}}
);
