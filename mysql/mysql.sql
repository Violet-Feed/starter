create database violet;

use violet;

create table conversation_core_info
(
    id           bigint auto_increment
        primary key,
    con_short_id bigint       not null,
    con_id       varchar(200) not null,
    con_type     int          not null,
    name         varchar(200) null,
    avatar_uri   varchar(200) null,
    description  varchar(500) null,
    notice       varchar(500) null,
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

create table conversation_setting_info
(
    id             bigint auto_increment
        primary key,
    user_id        bigint       not null,
    con_short_id   bigint       not null,
    con_type       int          not null,
    min_index      bigint       null,
    top_time_stamp bigint       null,
    push_status    int          null,
    modify_time    datetime     not null,
    extra          varchar(200) null,
    constraint `user_id:con_short_id`
        unique (user_id, con_short_id)
);

create table conversation_user_info
(
    id               bigint auto_increment
        primary key,
    con_short_id     bigint       not null,
    user_id          bigint       not null,
    privilege        int          not null,
    nick_name        varchar(200) null,
    block_time_stamp bigint       null,
    operator         bigint       not null,
    create_time      datetime     null,
    modify_time      datetime     null,
    status           int          null,
    extra            varchar(200) null,
    constraint `con_short_id:user_id`
        unique (con_short_id, user_id)
);

create table creation
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
    status        int           null,
    extra         varchar(200)  null,
    constraint creation_id
        unique (creation_id)
);

create table material
(
    id            bigint auto_increment
        primary key,
    material_id   bigint        not null,
    material_type int           not null,
    user_id       bigint        not null,
    prompt        varchar(1000) not null,
    source_url    varchar(200)  null,
    material_url  varchar(200)  not null,
    model         varchar(50)   not null,
    create_time   datetime      not null,
    status        int           not null,
    extra         varchar(200)  null,
    constraint material_id
        unique (material_id)
);

create index user_id
    on material (user_id);

create table user
(
    id       bigint auto_increment
        primary key,
    user_id  bigint       not null,
    username varchar(200) not null,
    avatar   varchar(200) null,
    password varchar(200) not null,
    constraint user_id
        unique (user_id)
);

