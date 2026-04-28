---
title: "VectorChord 1.1"
description: "Introducing rabitq8 and rabitq4 for major storage savings, plus per-index query defaults for composable multi-index workloads."
author: "vectorchord"
date: 2026-01-29
heroImage: /images/covers/vectorchord-1-1.svg
---

We’re excited to announce the release of VectorChord 1.1 as we kick off the new year of horse.

[VectorChord 1.0](https://blog.vectorchord.ai/vectorchord-10-developer-first-vector-search-on-postgres-100x-faster-indexing-than-pgvector) was a milestone for Postgres-native vector search: it made large-scale indexing fast enough to feel like iteration, not an outage. In 1.1, we’re building on that foundation with RaBitQ8: a new vector type that delivers 4x storage savings and faster search speeds compared to float32, all with less than 1% recall loss. Paired with RaBitQ4 and more composable query control, VectorChord 1.1 is ready for your most demanding production workloads.

This release focuses on two pain points we’ve observed through community feedback:

- **Capacity constraints.** When vector indexes grow massive, scaling isn't just about throughput. It is also about SSD footprint and buffer cache pressure.
- **Operational overhead.** As the number of indexes grows, manually setting search parameters (like `nprobe`) for every query clutters your application logic. This becomes a major headache in scenarios like partitioned tables, where individual indexes need distinct configurations. Relying on a global session variable (GUC) makes it impossible to tune these indexes independently.

VectorChord 1.1 addresses both. We’re introducing `rabitq8` and `rabitq4`, native quantized vector types that are 4x and 8x smaller than standard float32. These types shrink total index size by 4x-7x, drastically reducing storage overhead. We’ve also added per-index query defaults, allowing multi-index queries to rely on specific configurations rather than a brittle global PostgreSQL GUC.

## RaBitQ8 & RaBitQ4: Low-Bit Vector Type for Storage Efficiency

Vector data footprint is the hidden limiter of large-scale search on Postgres. Storing high-dimensional vectors as standard float32 (4 bytes per dimension) consumes massive amounts of SSD space and memory. As this footprint grows, it increases **buffer cache pressure** and forces queries to read from disk, causing P99 latency to spike.

VectorChord 1.1 solves this with two new quantized data types: `rabitq8` and `rabitq4`, built on extended RaBitQ ([paper](https://arxiv.org/abs/2409.09913)). By using 8-bit and 4-bit representations instead of 32-bit floats, these types reduce per-vector storage by 4x and 8x respectively, while keeping accuracy loss minimal.

Using these types is almost identical to using `vector`. The only difference is that you quantize values with `quantize_to_rabitq8` or `quantize_to_rabitq4` during `INSERT` and `SELECT`.

```pgsql
CREATE TABLE items (id bigserial PRIMARY KEY, embedding rabitq8(3));
CREATE INDEX ON items USING vchordrq (embedding rabitq8_l2_ops);
INSERT INTO items (embedding) VALUES (quantize_to_rabitq8('[0,0,0]'));
INSERT INTO items (embedding) VALUES (quantize_to_rabitq8('[1,1,1]'));
INSERT INTO items (embedding) VALUES (quantize_to_rabitq8('[2,2,2]'));
-- ...
SELECT id FROM items ORDER BY embedding <-> quantize_to_rabitq8('[1,2,3]') LIMIT 100;
```

On LAION with 100M 768-dimensional vectors, a typical `vector` (float32) index occupies about **400GB**. Using the `halfvec` (float16) type reduces that to roughly **171GB**. Under the same index options, switching to `rabitq8` further reduces it to about **95GB**, and `rabitq4` to around **58GB**, delivering a **4x to 7x** footprint reduction compared with the baseline.

![Index size comparison](https://cdn.hashnode.com/res/hashnode/image/upload/v1770862442344/781ef6d4-aa1e-4281-b306-7de000051672.png)

The next question is the recall and throughput trade-off. `rabitq8` delivers the index size reduction while keeping recall and QPS essentially on par with the baseline (`float32` vectors). `rabitq4` is a more aggressive option. It trades a larger recall loss for the smallest possible index size, and is best suited for deployments where storage is the primary constraint.

![Recall and QPS trade-off](https://cdn.hashnode.com/res/hashnode/image/upload/v1771052144440/61043c76-0e82-441a-bd3e-c0eeea17747c.png)

## Per-Index Query Defaults: Composable Multi-Index Queries

In VectorChord, the `vchordrq.probes` GUC controls how much of the vector space is searched at query time, directly trading off throughput against recall. For hierarchical `vchordrq` indexes, `vchordrq.probes` must have the same length as the `build.internal.lists` configuration used at build time. Typical configurations look like:

|  | `build.internal.lists` | `vchordrq.probes` |
| --- | --- | --- |
| No partition | `[]` | `''` |
| 1-layer partition | `[2000]` | `'40'` |
| 2-layer partition | `[800, 640000]` | `'40,200'` |

For simple vector search on a single table with a single index, setting the GUC once before running a query is a natural choice.

```pgsql
SET vchordrq.probes = '40';
```

However, the situation changes when a single query touches more than one vector index. Indexes built with different `build.internal.lists` configurations should logically use different probes settings. Worse, when the number of list levels differs, no single global probes value can simultaneously match both indexes, making the global setting inherently unsuitable for such queries.

```pgsql
CREATE INDEX idx_1 ON table_1 USING vchordrq (emb vector_cosine_ops);

CREATE INDEX idx_2 ON table_2 USING vchordrq (emb vector_cosine_ops) WITH (options = $$
[build.internal]
lists = [2000]
$$);

-- Bad: matches idx_2 configuration but not idx_1
SET vchordrq.probes = '40';
-- Bad: matches idx_1 configuration but not idx_2
SET vchordrq.probes = '';

-- Error: single global probes cannot satisfy both index configurations
SELECT 'table_1' AS src, id FROM table_1 ORDER BY emb <=> '[1,2,3]' LIMIT 5
UNION ALL
SELECT 'table_2' AS src, id FROM table_2 ORDER BY emb <=> '[4,5,6]' LIMIT 5;
```

To solve this, VectorChord 1.1 introduces per-index query defaults as index options, following PostgreSQL’s per-index configuration model. Instead of forcing every query to share a single global configuration, each index can now define its own defaults, which take effect when a global configuration is not explicitly set.

You can set per-index defaults at index creation time, and modify them at any time without rebuilding the index.

```pgsql
CREATE INDEX idx_1 ON table_1 USING vchordrq (emb vector_cosine_ops) WITH (options = $$
[build.internal]
lists = []
$$, probes = '');

CREATE INDEX idx_2 ON table_2 USING vchordrq (emb vector_cosine_ops) WITH (options = $$
[build.internal]
lists = [2000]
$$, probes = '20');

-- Modify per-index probes default online
ALTER INDEX idx_2 SET (probes = '40');

-- Success: the statement runs correctly with per-index defaults
SELECT 'table_1' AS src, id FROM table_1 ORDER BY emb <=> '[1,2,3]' LIMIT 5
UNION ALL
SELECT 'table_2' AS src, id FROM table_2 ORDER BY emb <=> '[4,5,6]' LIMIT 5;
```

In addition to `vchordrq.probes`, other query-time parameters can also be given per-index defaults at index creation time, so multi-index queries can rely on independent, index-specific settings. For the full list of configurable parameters, see [Fallback Parameters](https://docs.vectorchord.ai/vectorchord/usage/fallback-parameters.html).

## Summary

VectorChord 1.1 makes large-scale deployments easier to run. `rabitq8` and `rabitq4` significantly reduce storage size, lowering storage and memory pressure while preserving a familiar SQL usage pattern. Per-index fallback query defaults make multi-index vector queries possible within a single statement, especially when those indexes are built with different options.

Whether you are hitting storage and memory limits in real-world workloads or running complex queries with multiple vector indexes, we invite you to upgrade to VectorChord 1.1, try it on your own workloads, and share your feedback.

- **Download/Star on GitHub:** <https://github.com/tensorchord/VectorChord>
- **Join the Community:** <https://discord.gg/KqswhpVgdU>
