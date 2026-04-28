---
title: "VectorChord 0.5"
description: "Experimental DiskANN support plus a proactive recall measurement workflow for IVF+RaBitQ indexes."
author: "vectorchord"
pubDate: 2025-10-15
heroImage: ../../../assets/covers/vectorchord-0-5.svg
---

We're thrilled to announce the release of **VectorChord 0.5**! This release marks a significant step forward in our mission to provide more flexible, powerful, and controllable vector search capabilities. In the 0.5 release, we're introducing two major updates: **experimental support for the DiskANN graph index** and a new **recall measurement tool to monitor the health of your IVF+RaBitQ indexes proactively**.

## New Index Preview: RaBitQ-empowered DiskANN Index

From day one, VectorChord's core indexing solution has relied on a powerful combination: the cluster-based IVF algorithm and RaBitQ quantization, shipped as **vchordrq (IVF+RaBitQ)**. This approach consistently delivers excellent low-latency, high-recall performance across a wide range of use cases and remains **our recommended default** for most scenarios.

At the same time, we recognize that **graph-based indexes** can outperform IVF+RaBitQ **on certain datasets and at specific (often higher) recall targets**. To give you the best tool for every job, and because our goal is to be a **one-stop solution for vector search**, VectorChord 0.5 introduces **experimental support for the DiskANN algorithm** as an additional option.

### What is DiskANN and why does it matter?

Traditional top-tier graph algorithms (like HNSW and NSG) achieve their speed by keeping the entire graph in memory, which drives up hardware costs and caps single-node scale. SSDs are cheaper, but historically their random I/O made on-disk graphs impractical without big latency penalties.

**DiskANN's mission** is to break this memory barrier. It's a graph ANN designed from the ground up to store and search billion-scale datasets on inexpensive SSDs while maintaining competitive recall and low latency.

![DiskANN visualization](https://pic3.zhimg.com/80/v2-2d4c5810d8074f4faac3ed9f4ae7ad1e_720w.webp)

> A visualization from the original DiskANN paper.

#### How our variant differs

We implement a **variant of the original DiskANN design**: instead of the paper's default Product Quantization (PQ), our implementation uses **RaBitQ** as the quantization layer. **RaBitQ is more accurate and comes with theoretical guarantees**, which helps us deliver **better recall-latency trade-offs** compared with vanilla PQ used in original implementations. In practice, this change enables stronger accuracy at the same footprint or faster queries at the same recall.

In VectorChord 0.5, we've integrated DiskANN into the existing ecosystem so you can evaluate it side-by-side with vchordrq.

**When DiskANN can shine**

- **Workload + target dependent gains.** For some model families (for example, OpenAI/Cohere-style embeddings) and **high-recall settings**, DiskANN can deliver **lower latency and/or higher recall** than IVF+RaBitQ on the same hardware.
- **Stable and predictable build memory.** It avoids the KMeans phase of IVF, reducing memory fluctuations during index build and simplifying capacity planning.
- **Ecosystem compatibility.** Keep using **VBase** for metadata filtering and **RaBitQ quantization** for smaller footprint and faster re-ranking.

### Important considerations (read this first)

DiskANN is still **experimental** in VectorChord, and like all graph ANN methods, it entails trade-offs:

- **Updates and build speed.** **Index builds and updates are much slower than with vchordrq (IVF+RaBitQ).** If you have frequent inserts/deletes or need fast rebuilds, vchordrq is the better fit.
- **Dynamic data performance.** Modifying graph connectivity is computationally heavier than updating IVF lists; expect better operational ergonomics with vchordrq for mutable datasets.
- **Operational simplicity.** vchordrq tends to be simpler to tune and operate for most teams.

> **Our recommendation:** Start with **vchordrq (IVF+RaBitQ)** for the majority of use cases. Consider **DiskANN** when you're chasing **top-tier recall on relatively static corpora**, want **tighter tail latency at high recall**, or when **build-time memory predictability** is a hard requirement. Your feedback will help us harden this option for production.

### How to get started

```bash
docker run \
  --name vectorchord-demo \
  -e POSTGRES_PASSWORD=mysecretpassword \
  -p 5432:5432 \
  -d tensorchord/vchord-postgres:pg17-v0.5.2
```

```pgsql
-- 1. Enable the VectorChord extension
postgres=# CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
NOTICE:  installing required extension "vector"
CREATE EXTENSION
postgres=# \dx
                                                 List of installed extensions
  Name   | Version |   Schema   |                                         Description
---------+---------+------------+---------------------------------------------------------------------------------------------
 plpgsql | 1.0     | pg_catalog | PL/pgSQL procedural language
 vchord  | 0.5.0   | public     | vchord: Vector database plugin for Postgres, written in Rust, specifically designed for LLM
 vector  | 0.8.0   | public     | vector data type and ivfflat and hnsw access methods
(3 rows)

-- 2. Create a table with a vector column
postgres=# CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(3));
CREATE TABLE
-- 3. Insert some sample data
postgres=# INSERT INTO items (embedding) SELECT ARRAY[random(), random(), random()]::real[] FROM generate_series(1, 1000);
INSERT 0 1000
-- 4. Build the DiskANN graph index using the 'vchordg' method
postgres=# CREATE INDEX ON items USING vchordg (embedding vector_l2_ops);
CREATE INDEX
-- 5. Run an approximate nearest neighbor search!
postgres=# SELECT * FROM items ORDER BY embedding <-> '[3,1,2]' LIMIT 5;
 id  |             embedding
-----+-----------------------------------
 370 | [0.9644321,0.7480163,0.95816356]
 186 | [0.9583021,0.6364455,0.9882274]
 303 | [0.9735422,0.9101731,0.92470014]
 793 | [0.93719786,0.8919436,0.9729206]
 432 | [0.97542423,0.62692064,0.9525037]
(5 rows)
```

Check out our official documentation for detailed instructions on configuring and using the new graph index: [**Guide to Using Graph Index in VectorChord**](https://docs.vectorchord.ai/vectorchord/usage/graph-index.html)

## Proactive Monitoring: Recall Measurement Tool for IVF+RaBitQ

A potential challenge with vector search indexes is **data distribution drift**. As you continuously add new data, especially when the new data's vector distribution differs significantly from the initial dataset, the index's recall can degrade over time and impact query quality.

Previously, quantifying this degradation was difficult, often relying on intuition or complex offline evaluations to decide when an index rebuild was necessary.

To empower you to proactively and easily monitor your index's health, version 0.5 introduces a powerful new function: `vchordrq_evaluate_query_recall`.

This function allows you to use a small, representative set of query vectors and their ground truth nearest neighbors to quickly and accurately assess the actual recall of your current IVF+RaBitQ index.

**What it does for you**

- **Quantify performance.** Turn the "feel" of your index's quality into a hard, measurable number.
- **Inform decisions.** By running evaluations periodically, you can clearly visualize the recall trend and make data-driven decisions on when to rebuild your index for optimal performance.
- **Enhance service quality.** Ensure your live vector search service consistently meets its quality SLAs and prevent business impact from silent index degradation.

### How to use it

```pgsql
-- Select ctid from your vector table with the target query vector to evaluate
postgres=# SELECT vchordrq_evaluate_query_recall(query => $$
  SELECT ctid FROM items ORDER BY embedding <-> '[3,1,2]' LIMIT 10$$);
 vchordrq_evaluate_query_recall
--------------------------------
                              1
(1 row)
```

For more details and configuration, refer to [**Measuring Recall for IVF+RaBitQ Indexes**](https://docs.vectorchord.ai/vectorchord/usage/measure-recall.html).

## Automatically Record Queries for Recall Tracking

Keeping a high-quality vector search service is not just about measuring recall once; it is about measuring it continually on **real traffic**. Starting in **v0.5.2**, VectorChord can **automatically record (sample) your production queries** so you can evaluate recall on the exact vectors users searched for.

### Why it matters

- **Hands-off data collection.** No custom logging pipelines or app changes.
- **Representative signals.** Evaluate recall on the same distributions your system sees in production.
- **Privacy-aware and lightweight.** You control when sampling is enabled and how much to collect.

### Enable query sampling

```sql
-- Turn on sampling and set sensible limits
SET vchordrq.query_sampling_enable = on;
SET vchordrq.query_sampling_max_records = 1000;  -- cap the total stored samples
SET vchordrq.query_sampling_rate = 0.01;         -- sample every 100 query (adjust as needed)
```

After enabling, run your normal vector searches (for example, `SELECT * FROM items ORDER BY embedding <-> '[3,1,2]' LIMIT 10;`). VectorChord will capture the essential components of each sampled query: **schema, index, table, column, operator, and vector value**.

### Inspect what was recorded

```sql
SELECT * FROM vchordrq_sampled_queries('items_embedding_idx');
-- schema_name | index_name          | table_name | column_name | operator |    value
-- ------------+---------------------+------------+-------------+----------+--------------
-- public      | items_embedding_idx | items      | embedding   | <->      | [0.5,0.25,1]
```

### Evaluate recall on recorded queries

```sql
SELECT AVG(recall_value) FROM (
    SELECT vchordrq_evaluate_query_recall(
            format(
                'SELECT ctid FROM %I.%I ORDER BY %I OPERATOR(%s) %L LIMIT 10',
                lq.schema_name,
                lq.table_name,
                lq.column_name,
                lq.operator,
                lq.value
            )
    ) AS recall_value
    FROM vchordrq_sampled_queries('items_embedding_idx') AS lq
) AS eval_results;
```

> **Note:** If you run PostgreSQL replication with primary/standby servers, sampled queries are **not** synchronized via replication or backup. Each server records its **own** queries based on the traffic it serves.

## Summary

VectorChord 0.5 brings unprecedented flexibility to our users. Experimental DiskANN support offers a new high-performance option for specific workloads, while the recall measurement tool gives you fine-grained monitoring over the operational health of your existing IVF indexes.

We believe that empowering users with more choices and greater control is the driving force behind VectorChord's evolution. We sincerely invite you to try out the new version and share your feedback, especially on how DiskANN performs in your real-world scenarios.

- **Download/Star on GitHub:** <https://github.com/tensorchord/VectorChord>
- **Join the Community:** <https://discord.gg/KqswhpVgdU>

Ready to take it for a spin? Head over to our GitHub repository, download the latest release, and see what VectorChord 0.5 can do for you.
