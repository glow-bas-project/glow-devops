-- First-time Postgres init only (docker-entrypoint-initdb.d).
-- When adding a service, also add its name to postgres/databases.txt for compose-up.sh.

CREATE DATABASE keycloak;
CREATE DATABASE glow_restaurant;
CREATE DATABASE glow_user;
CREATE DATABASE glow_order;
CREATE DATABASE glow_cart;
CREATE DATABASE glow_courier;
CREATE DATABASE glow_menu;
CREATE DATABASE glow_payment;
