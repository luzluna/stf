
CREATE TABLE storage (
       id INT NOT NULL PRIMARY KEY,
       uri VARCHAR(100) NOT NULL,
       mode TINYINT NOT NULL DEFAULT 1,
       created_at INT NOT NULL,
       updated_at TIMESTAMP,
       UNIQUE KEY(uri),
       KEY(mode)
) ENGINE=InnoDB;

/*
    storage_meta - Used to store storage meta data.

    This is a spearate table because historically the 'storage' table
    was declared without a character set declaration, and things go
    badly when multibyte 'notes' are added.

    Make sure to place ONLY items that has nothing to do with the
    core STF functionality here.

    XXX Theoretically this table could be in a different database
    than the main mysql instance.
*/
CREATE TABLE storage_meta (
    storage_id INT NOT NULL PRIMARY KEY,
    used       BIGINT UNSIGNED DEFAULT 0,
    capacity   BIGINT UNSIGNED DEFAULT 0,
    notes      TEXT,
    /* XXX if we move this table to a different database, then
       this foreign key is moot. this is placed where because I'm 
       too lazy to cleanup the database when we delete the storage
    */
    FOREIGN KEY(storage_id) REFERENCES storage(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE bucket (
       id BIGINT NOT NULL PRIMARY KEY,
       name VARCHAR(255) NOT NULL,
       objects BIGINT UNSIGNED NOT NULL DEFAULT 0,
       created_at INT NOT NULL,
       updated_at TIMESTAMP,
       UNIQUE KEY(name)
) ENGINE=InnoDB;

CREATE TABLE object (
       id BIGINT NOT NULL PRIMARY KEY,
       bucket_id BIGINT NOT NULL,
       name VARCHAR(255) NOT NULL,
       internal_name VARCHAR(128) NOT NULL,
       size INT NOT NULL DEFAULT 0,
       num_replica INT NOT NULL DEFAULT 1,
       status TINYINT DEFAULT 1 NOT NULL,
       created_at INT NOT NULL,
       updated_at TIMESTAMP,
       UNIQUE KEY(bucket_id, name),
       UNIQUE KEY(internal_name)
) ENGINE=InnoDB;

/* object_meta - same caveats as storage_meta applies */
CREATE TABLE object_meta (
    object_id BIGINT NOT NULL PRIMARY KEY,
    hash      CHAR(32),
    FOREIGN KEY(object_id) REFERENCES object(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE deleted_object ENGINE=InnoDB SELECT * FROM object LIMIT 0;
ALTER TABLE deleted_object ADD PRIMARY KEY(id);
-- ALTER TABLE deleted_object ADD UNIQUE KEY(internal_name);
CREATE TABLE deleted_bucket ENGINE=InnoDB SELECT * FROM bucket LIMIT 0;
ALTER TABLE deleted_bucket ADD PRIMARY KEY(id);

CREATE TABLE entity (
       object_id BIGINT NOT NULL,
       storage_id INT NOT NULL,
       status TINYINT DEFAULT 1 NOT NULL,
       created_at INT NOT NULL,
       updated_at TIMESTAMP,
       PRIMARY KEY id (object_id, storage_id),
       KEY(object_id, status),
       KEY(storage_id),
       FOREIGN KEY(storage_id) REFERENCES storage(id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE config (
    varname  VARCHAR(127) PRIMARY KEY,
    varvalue VARCHAR(127)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE worker (
    id         CHAR(32) NOT NULL PRIMARY KEY,
    expires_at DATETIME NOT NULL
) ENGINE=InnoDB;

