-- Allani schema upgrade 5 -> 6: the managed_indexes table
--
-- Records the user-managed per-enriched-field indexes (the droppable ones),
-- moving that intent out of the config and into the database. Only indexes
-- named allani_ix_* are tracked here; the schema-required indexes (primary
-- keys, the raw GIN, the (column, id) composites, the timestamp btrees) are
-- deliberately absent, which is what makes `allani index drop` unable to touch
-- them.

CREATE TABLE managed_indexes (
    id bigserial NOT NULL,
    tbl varchar(64) NOT NULL,
    field varchar(255) NOT NULL,
    trigram boolean NOT NULL DEFAULT false,
    index_name varchar(63) NOT NULL,
    created TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    PRIMARY KEY(id),
    UNIQUE (index_name),
    UNIQUE (tbl, field, trigram)
);
