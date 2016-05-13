-- Create database owner
CREATE ROLE "dorscluc_user" PASSWORD 'dorscluc_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN;

-- Create database
CREATE DATABASE "dorscluc_db" OWNER "dorscluc_user" ENCODING 'utf8' TEMPLATE "template1";
