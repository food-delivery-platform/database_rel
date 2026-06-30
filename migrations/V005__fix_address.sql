alter table addresses
    rename column line1 to line;

alter table addresses
    drop column line2;

alter table addresses
    drop column district;

alter table addresses
    drop column postal_code;

