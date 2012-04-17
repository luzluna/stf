CREATE TABLE config (
    varname VARCHAR(127) NOT NULL PRIMARY KEY,
    varvalue TEXT
) ENGINE=InnoDB;

CREATE TABLE storage_cluster (
    id INT NOT NULL PRIMARY KEY,
    name VARCHAR(128),
    mode TINYINT NOT NULL DEFAULT 1,
    KEY (mode)
) ENGINE=InnoDB;

CREATE TABLE storage (
       id INT NOT NULL PRIMARY KEY,
       cluster_id INT,
       uri VARCHAR(100) NOT NULL,
       mode TINYINT NOT NULL DEFAULT 1,
       created_at INT NOT NULL,
       updated_at TIMESTAMP,
       FOREIGN KEY(cluster_id) REFERENCES storage_cluster (id) ON DELETE SET NULL,
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

/* object_cluster_map 
    maps objects to clusters
*/
CREATE TABLE object_cluster_map (
    object_id BIGINT NOT NULL PRIMARY KEY,
    cluster_id INT NOT NULL,
    FOREIGN KEY (object_id) REFERENCES object (id) ON DELETE CASCADE,
    FOREIGN KEY (cluster_id) REFERENCES storage_cluster (id) ON DELETE CASCADE,
    KEY (cluster_id)
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

DELIMITER $$
CREATE PROCEDURE stfVerifyClusterMode(x_cluster_id INT)
BEGIN
    DECLARE good_count INT;
    SELECT COUNT(*) INTO good_count FROM storage WHERE cluster_id = x_cluster_id AND MODE = 1;

    IF ( good_count < 3 ) THEN
        UPDATE storage_cluster SET mode = 0 WHERE id = x_cluster_id;
    END IF;
END
$$

CREATE TRIGGER storage_update_trig AFTER UPDATE ON storage
    FOR EACH ROW BEGIN
        CALL stfVerifyClusterMode(NEW.cluster_id);
    END;
$$ 

DELIMITER ;

