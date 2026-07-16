-- Allani schema downgrade 6 -> 5: drop the managed_indexes table
--
-- The allani_ix_* indexes it tracked are left in place; recreate the table and
-- `allani index import`/re-add to manage them again.

DROP TABLE managed_indexes;
