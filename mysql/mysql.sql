create table violet.agent
(
    id          bigint auto_increment
        primary key,
    agent_id    bigint        not null,
    agent_name  varchar(200)  not null,
    avatar_uri  varchar(200)  null,
    description varchar(500)  null,
    personality varchar(1000) not null,
    owner_id    bigint        not null,
    create_time datetime      not null,
    modify_time datetime      not null,
    status      int           null,
    extra       varchar(200)  null,
    constraint agent_id
        unique (agent_id)
);

create table violet.chatbot_memory_glossary
(
    id           bigint auto_increment
        primary key,
    con_short_id bigint                  not null,
    term         varchar(100)            not null,
    meaning      varchar(500) default '' not null,
    count        int          default 1  not null,
    updated_at   bigint                  not null,
    constraint `con_short_id:term`
        unique (con_short_id, term)
);

create table violet.chatbot_memory_summary
(
    id               bigint auto_increment
        primary key,
    con_short_id     bigint           not null,
    short_summary    text             not null,
    long_summary     text             not null,
    short_version    int    default 0 not null,
    long_version     int    default 0 not null,
    short_updated_at bigint default 0 not null,
    long_updated_at  bigint default 0 not null,
    updated_at       bigint           not null,
    constraint con_short_id
        unique (con_short_id)
);

create table violet.conversation_agent_info
(
    id           bigint auto_increment
        primary key,
    con_short_id bigint       not null,
    agent_id     bigint       not null,
    create_time  datetime     not null,
    modify_time  datetime     not null,
    status       int          null,
    extra        varchar(200) null,
    constraint `con_short_id:agent_id`
        unique (con_short_id, agent_id)
);

create table violet.conversation_core_info
(
    id           bigint auto_increment
        primary key,
    con_short_id bigint       not null,
    con_id       varchar(200) not null,
    con_type     int          not null,
    name         varchar(200) null,
    avatar_uri   varchar(200) null,
    description  varchar(500) null,
    owner_id     bigint       not null,
    create_time  datetime     not null,
    modify_time  datetime     not null,
    status       int          null,
    extra        varchar(200) null,
    constraint con_id
        unique (con_id),
    constraint con_short_id
        unique (con_short_id)
);

create table violet.conversation_setting_info
(
    id            bigint auto_increment
        primary key,
    user_id       bigint       not null,
    con_short_id  bigint       not null,
    con_type      int          not null,
    min_index     bigint       null,
    top_timestamp bigint       null,
    push_status   int          null,
    modify_time   datetime     not null,
    extra         varchar(200) null,
    constraint `user_id:con_short_id`
        unique (user_id, con_short_id)
);

create table violet.conversation_user_info
(
    id           bigint auto_increment
        primary key,
    con_short_id bigint       not null,
    user_id      bigint       not null,
    privilege    int          not null,
    nick_name    varchar(200) null,
    create_time  datetime     not null,
    modify_time  datetime     not null,
    status       int          null,
    extra        varchar(200) null,
    constraint `con_short_id:user_id`
        unique (con_short_id, user_id)
);

create table violet.creation
(
    id            bigint auto_increment
        primary key,
    creation_id   bigint        not null,
    user_id       bigint        not null,
    cover_url     varchar(200)  null,
    material_id   bigint        not null,
    material_type int           not null,
    material_url  varchar(200)  null,
    title         varchar(200)  not null,
    content       varchar(1000) null,
    category      varchar(50)   null,
    create_time   datetime      not null,
    modify_time   datetime      not null,
    status        int           not null,
    extra         varchar(200)  null,
    constraint creation_id
        unique (creation_id)
);

create table violet.material
(
    id            bigint auto_increment
        primary key,
    material_id   bigint        not null,
    material_type int           not null,
    user_id       bigint        not null,
    prompt        varchar(1000) not null,
    source_url    varchar(200)  null,
    material_url  varchar(200)  not null,
    cover_url     varchar(200)  not null,
    model         varchar(50)   not null,
    create_time   datetime      not null,
    status        int           not null,
    extra         varchar(200)  null,
    constraint material_id
        unique (material_id)
);

create index user_id
    on violet.material (user_id);

create table violet.user
(
    id          bigint auto_increment
        primary key,
    user_id     bigint       not null,
    username    varchar(200) not null,
    avatar      varchar(200) null,
    password    varchar(200) not null,
    create_time datetime     not null,
    modify_time datetime     not null,
    status      int          not null,
    extra       varchar(200) null,
    constraint user_id
        unique (user_id)
);
