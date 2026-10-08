# Reserve 1.6.5

Saved local activity now appears when Reserve starts. During a new scan, the
provider details keep those totals visible and say that activity is updating.

Large Claude session files can need several scan passes. Reserve now saves
complete lines before a pass reaches its time or byte limit, so the next pass
continues from that point. An unfinished scan keeps the previous complete totals.
